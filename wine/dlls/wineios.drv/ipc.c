/* Juice cross-process display transport. LGPL-2.1-or-later. */
#if 0
#pragma makedep unix
#endif
#include "config.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>
#include "ipc.h"
#include "wine/server.h"
WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);

static int ipc_fd=-1;
static pthread_mutex_t ipc_lock=PTHREAD_MUTEX_INITIALIZER;
static char ipc_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static unsigned int ipc_width=1024,ipc_height=768,ipc_dpi=96;
static unsigned int ipc_generation;
static __thread unsigned int queue_generation;
static HWND input_target;
static BOOL pointer_down;

struct ipc_surface_generation
{
 HWND hwnd;
 unsigned int generation;
 struct ipc_surface_generation *next;
};
static struct ipc_surface_generation *surface_generations;

static BOOL write_all(int fd,const void *data,size_t size){const char *p=data;while(size){ssize_t n=write(fd,p,size);if(n<0&&errno==EINTR)continue;if(n<=0)return FALSE;p+=n;size-=n;}return TRUE;}
static BOOL read_all(int fd,void *data,size_t size){char *p=data;while(size){ssize_t n=read(fd,p,size);if(n<0&&errno==EINTR)continue;if(n<=0)return FALSE;p+=n;size-=n;}return TRUE;}

static BOOL writev_all(int fd,struct iovec *iov,int count)
{
 while(count)
 {
  ssize_t written=writev(fd,iov,count);
  if(written<0&&errno==EINTR) continue;
  if(written<=0) return FALSE;
  while(count&&written>=(ssize_t)iov->iov_len)
  {
   written-=iov->iov_len;
   iov++;
   count--;
  }
  if(count&&written)
  {
   iov->iov_base=(char *)iov->iov_base+written;
   iov->iov_len-=written;
  }
 }
 return TRUE;
}

static void disconnect_ipc_locked(void)
{
 if(ipc_fd>=0) close(ipc_fd);
 ipc_fd=-1;
}

static void disconnect_ipc_fd(int fd)
{
 pthread_mutex_lock(&ipc_lock);
 if(ipc_fd==fd) disconnect_ipc_locked();
 pthread_mutex_unlock(&ipc_lock);
}

static BOOL surface_has_baseline_locked(HWND hwnd)
{
 struct ipc_surface_generation *entry;
 for(entry=surface_generations;entry;entry=entry->next)
  if(entry->hwnd==hwnd) return entry->generation==ipc_generation;
 return FALSE;
}

static void mark_surface_baseline_locked(HWND hwnd)
{
 struct ipc_surface_generation *entry;
 for(entry=surface_generations;entry;entry=entry->next)
  if(entry->hwnd==hwnd)
  {
   entry->generation=ipc_generation;
   return;
  }
 if((entry=malloc(sizeof(*entry))))
 {
  entry->hwnd=hwnd;
  entry->generation=ipc_generation;
  entry->next=surface_generations;
  surface_generations=entry;
 }
}

static void forget_surface_locked(HWND hwnd)
{
 struct ipc_surface_generation **cursor;
 for(cursor=&surface_generations;*cursor;cursor=&(*cursor)->next)
  if((*cursor)->hwnd==hwnd)
  {
   struct ipc_surface_generation *entry=*cursor;
   *cursor=entry->next;
   free(entry);
   return;
  }
}

static BOOL connect_ipc_locked(void)
{
 struct sockaddr_un addr;
 struct juice_ios_msg hello;
 int fd,one=1;

 if(ipc_fd>=0) return TRUE;
 if(!ipc_path[0]) return FALSE;

 memset(&addr,0,sizeof(addr));
 addr.sun_family=AF_UNIX;
 strcpy(addr.sun_path,ipc_path);
 if((fd=socket(AF_UNIX,SOCK_STREAM,0))<0) return FALSE;
#ifdef SO_NOSIGPIPE
 setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#else
 (void)one;
#endif
 if(connect(fd,(struct sockaddr *)&addr,sizeof(addr))<0)
 {
  close(fd);
  return FALSE;
 }

 memset(&hello,0,sizeof(hello));
 hello.magic=JUICE_IOS_MAGIC;
 hello.type=JUICE_IOS_HELLO;
 hello.width=ipc_width;
 hello.height=ipc_height;
 hello.stride=ipc_dpi;
 hello.flags=(UINT)getpid();
 if(!write_all(fd,&hello,sizeof(hello)))
 {
  close(fd);
  return FALSE;
 }

 ipc_fd=fd;
 if(++ipc_generation==0) ++ipc_generation;
 fprintf(stderr,"[JuiceIPC] connected fd=%d generation=%u desktop=%ux%u dpi=%u\n",
         ipc_fd,ipc_generation,ipc_width,ipc_height,ipc_dpi);
 return TRUE;
}

static void send_msg(UINT type,HWND hwnd,const RECT *rect,const void *payload,UINT size,UINT stride,UINT flags)
{
 struct juice_ios_msg msg={JUICE_IOS_MAGIC,type,size,(UINT64)(UINT_PTR)hwnd};
 BOOL connected=FALSE;
 if(rect){msg.x=rect->left;msg.y=rect->top;msg.width=rect->right-rect->left;msg.height=rect->bottom-rect->top;}
 msg.stride=stride;msg.flags=flags;

 pthread_mutex_lock(&ipc_lock);
 if(connect_ipc_locked())
 {
  if(write_all(ipc_fd,&msg,sizeof(msg))&&(!size||write_all(ipc_fd,payload,size))) connected=TRUE;
  else disconnect_ipc_locked();
 }
 pthread_mutex_unlock(&ipc_lock);
 if(connected) ios_ipc_register_queue();
}

static UINT send_virtual_key(HWND target,WORD vkey)
{
 INPUT input={0};
 UINT sent=0;
 input.type=INPUT_KEYBOARD;
 input.ki.wVk=vkey;
 input.ki.wScan=0;
 input.ki.dwFlags=0;
 input.ki.time=0;
 input.ki.dwExtraInfo=0;
 sent+=NtUserSendHardwareInput(target,0,&input,0);
 input.ki.dwFlags=KEYEVENTF_KEYUP;
 sent+=NtUserSendHardwareInput(target,0,&input,0);
 return sent;
}

BOOL ios_ipc_process_input(void)
{
 for(;;)
 {
  struct juice_ios_msg msg;
  INPUT input={0};
  void *payload=NULL;
  HWND hwnd,target;
  RECT window;
  UINT sent=0,units=0,i;
  LRESULT text_length=0;
  BOOL redrawn=FALSE,presented=FALSE;
  ssize_t available;
  int fd;

  pthread_mutex_lock(&ipc_lock);
  if(ipc_fd<0) connect_ipc_locked();
  fd=ipc_fd;
  pthread_mutex_unlock(&ipc_lock);
  if(fd<0) break;
  ios_ipc_register_queue();

  available=recv(fd,&msg,sizeof(msg),MSG_PEEK|MSG_DONTWAIT);
  if(available==0)
  {
   disconnect_ipc_fd(fd);
   break;
  }
  if(available<0)
  {
   if(errno==EINTR) continue;
   if(errno!=EAGAIN&&errno!=EWOULDBLOCK) disconnect_ipc_fd(fd);
   break;
  }
  if(available<(ssize_t)sizeof(msg)) break;
  if(!read_all(fd,&msg,sizeof(msg)))
  {
   disconnect_ipc_fd(fd);
   break;
  }
  if(msg.size>64u*1024u)
  {
   fprintf(stderr,"[JuiceInput] rejected oversized message type=%u size=%u\n",msg.type,msg.size);
   disconnect_ipc_fd(fd);
   break;
  }
  if(msg.size)
  {
   payload=malloc(msg.size);
   if(!payload||!read_all(fd,payload,msg.size))
   {
    free(payload);
    disconnect_ipc_fd(fd);
    break;
   }
  }
  if(msg.magic!=JUICE_IOS_MAGIC)
  {
   fprintf(stderr,"[JuiceInput] ignored invalid magic=%08x type=%u size=%u\n",msg.magic,msg.type,msg.size);
   free(payload);
   continue;
  }

  hwnd=(HWND)(UINT_PTR)msg.hwnd;
  if(msg.type==JUICE_IOS_INPUT&&!msg.size)
  {
   BOOL desktop_coords=(msg.flags&JUICE_IOS_COORDS_DESKTOP)!=0;
   BOOL down=(msg.flags&(JUICE_IOS_LEFT_DOWN|JUICE_IOS_RIGHT_DOWN))!=0;
   BOOL up=(msg.flags&(JUICE_IOS_LEFT_UP|JUICE_IOS_RIGHT_UP))!=0;
   INT local_x=msg.x,local_y=msg.y;

   input.type=INPUT_MOUSE;
   if(desktop_coords)
   {
    /*
     * Keep the hardware pointer in screen space for the whole drag. The host
     * used to subtract an old window origin and this side then added a newer
     * one, which made moving windows oscillate behind the finger.
     */
    input.mi.dx=msg.x;
    input.mi.dy=msg.y;

    if(pointer_down&&input_target&&!down) target=input_target;
    else
    {
     if(NtUserGetWindowRect(hwnd,&window,NtUserGetDpiForWindow(hwnd)))
     {
      local_x-=window.left;
      local_y-=window.top;
     }
     target=NtUserChildWindowFromPointEx(hwnd,local_x,local_y,
                                         CWP_SKIPINVISIBLE|CWP_SKIPDISABLED|CWP_SKIPTRANSPARENT);
     if(!target||target==hwnd) target=NtUserWindowFromPoint(msg.x,msg.y);
     if(!target) target=hwnd;
    }
   }
   else
   {
    input.mi.dx=msg.x;
    input.mi.dy=msg.y;
    target=NtUserChildWindowFromPointEx(hwnd,msg.x,msg.y,
                                        CWP_SKIPINVISIBLE|CWP_SKIPDISABLED|CWP_SKIPTRANSPARENT);
    if(NtUserGetWindowRect(hwnd,&window,NtUserGetDpiForWindow(hwnd)))
    {
     input.mi.dx+=window.left;
     input.mi.dy+=window.top;
    }
    if(!target||target==hwnd) target=NtUserWindowFromPoint(input.mi.dx,input.mi.dy);
    if(!target) target=hwnd;
   }

   if(down)
   {
    NtUserSetForegroundWindow(hwnd);
    NtUserSetActiveWindow(hwnd);
    NtUserSetFocus(target);
    input_target=target;
    pointer_down=TRUE;
   }
   input.mi.dwFlags=MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_MOVE|MOUSEEVENTF_MOVE_NOCOALESCE;
   if(msg.flags&JUICE_IOS_LEFT_DOWN) input.mi.dwFlags|=MOUSEEVENTF_LEFTDOWN;
   if(msg.flags&JUICE_IOS_LEFT_UP) input.mi.dwFlags|=MOUSEEVENTF_LEFTUP;
   if(msg.flags&JUICE_IOS_RIGHT_DOWN) input.mi.dwFlags|=MOUSEEVENTF_RIGHTDOWN;
   if(msg.flags&JUICE_IOS_RIGHT_UP) input.mi.dwFlags|=MOUSEEVENTF_RIGHTUP;
   sent=NtUserSendHardwareInput(target,0,&input,0);
   if(up) pointer_down=FALSE;
   fprintf(stderr,"[JuiceInput] dispatched surface=%p target=%p coords=%s wire=%d,%d desktop=%d,%d flags=%x sent=%u\n",
           hwnd,target,desktop_coords?"desktop":"local",msg.x,msg.y,input.mi.dx,input.mi.dy,input.mi.dwFlags,sent);
  }
  else if(msg.type==JUICE_IOS_TEXT&&msg.size&&!(msg.size%sizeof(WCHAR)))
  {
   target=input_target?input_target:hwnd;
   NtUserSetForegroundWindow(hwnd);
   NtUserSetActiveWindow(hwnd);
   NtUserSetFocus(target);
   units=msg.size/sizeof(WCHAR);
   for(i=0;i<units;i++)
   {
    NtUserMessageCall(target,WM_CHAR,((WCHAR *)payload)[i],1,NULL,NtUserSendMessage,FALSE);
    sent++;
   }
   text_length=NtUserMessageCall(target,WM_GETTEXTLENGTH,0,0,NULL,NtUserSendMessage,FALSE);
   redrawn=NtUserRedrawWindow(target,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   redrawn|=NtUserRedrawWindow(hwnd,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   presented=iosdrv_present_now(hwnd);
   fprintf(stderr,"[JuiceInput] text surface=%p target=%p utf16_units=%u delivered=%u length=%ld redraw=%u present=%u\n",hwnd,target,units,sent,(long)text_length,redrawn,presented);
  }
  else if(msg.type==JUICE_IOS_KEY&&!msg.size&&(msg.flags&0xffffu))
  {
   WORD vkey=msg.flags&0xffffu;
   target=input_target?input_target:hwnd;
   NtUserSetForegroundWindow(hwnd);
   NtUserSetActiveWindow(hwnd);
   NtUserSetFocus(target);
   sent=send_virtual_key(target,vkey);
   fprintf(stderr,"[JuiceInput] key surface=%p target=%p vk=%x hardware_events=%u\n",
           hwnd,target,vkey,sent);
  }
  else
  {
   fprintf(stderr,"[JuiceInput] ignored invalid message type=%u size=%u flags=%x\n",
           msg.type,msg.size,msg.flags);
  }
  free(payload);
 }
 return TRUE;
}

void ios_ipc_register_queue(void)
{
 HANDLE handle;
 int ret,fd;
 unsigned int generation;

 pthread_mutex_lock(&ipc_lock);
 fd=ipc_fd;
 generation=ipc_generation;
 if(fd<0||queue_generation==generation)
 {
  pthread_mutex_unlock(&ipc_lock);
  return;
 }
 if(wine_server_fd_to_handle(fd,GENERIC_READ|SYNCHRONIZE,0,&handle))
 {
  pthread_mutex_unlock(&ipc_lock);
  fprintf(stderr,"[JuiceInput] failed to allocate queue fd handle tid=%p\n",NtCurrentTeb()->ClientId.UniqueThread);
  return;
 }
 pthread_mutex_unlock(&ipc_lock);

 SERVER_START_REQ(set_queue_fd)
 {
  req->handle=wine_server_obj_handle(handle);
  ret=wine_server_call(req);
 }
 SERVER_END_REQ;
 NtClose(handle);
 if(ret) fprintf(stderr,"[JuiceInput] failed to register queue fd status=%x tid=%p\n",ret,NtCurrentTeb()->ClientId.UniqueThread);
 else
 {
  pthread_mutex_lock(&ipc_lock);
  if(ipc_fd==fd&&ipc_generation==generation) queue_generation=generation;
  pthread_mutex_unlock(&ipc_lock);
  fprintf(stderr,"[JuiceInput] queue fd registered fd=%d generation=%u tid=%p\n",
          fd,generation,NtCurrentTeb()->ClientId.UniqueThread);
 }
}

void ios_ipc_init(unsigned int width,unsigned int height,unsigned int dpi)
{
 const char *path=getenv("JUICE_IOS_SOCKET");
 BOOL connected=FALSE;

 if(!path||!*path||strlen(path)>=sizeof(ipc_path)) return;
 pthread_mutex_lock(&ipc_lock);
 strcpy(ipc_path,path);
 ipc_width=width;
 ipc_height=height;
 ipc_dpi=dpi;
 connected=connect_ipc_locked();
 pthread_mutex_unlock(&ipc_lock);
 if(connected) ios_ipc_register_queue();
}

void ios_ipc_window(HWND hwnd,const RECT *rect,BOOL visible){send_msg(JUICE_IOS_WINDOW,hwnd,rect,NULL,0,0,visible);}
void ios_ipc_destroy(HWND hwnd)
{
 send_msg(JUICE_IOS_DESTROY,hwnd,NULL,NULL,0,0,0);
 pthread_mutex_lock(&ipc_lock);
 forget_surface_locked(hwnd);
 pthread_mutex_unlock(&ipc_lock);
}

void ios_ipc_present(HWND hwnd,const void *bits,unsigned int width,unsigned int height,unsigned int stride,const RECT *dirty)
{
 struct juice_ios_msg msg={JUICE_IOS_MAGIC,JUICE_IOS_FRAME,0,(UINT64)(UINT_PTR)hwnd};
 const unsigned char *source=bits;
 size_t full_size,payload_size,row_bytes;
 unsigned int dirty_width,dirty_height,row,start,count;
 RECT clipped;
 BOOL partial,connected=FALSE,success=FALSE;
 struct iovec rows[64];

 if(!bits||!width||!height||stride<width*4u) return;
 full_size=(size_t)stride*height;
 if(full_size>UINT_MAX) return;

 SetRect(&clipped,0,0,width,height);
 if(dirty)
 {
  if(dirty->left>clipped.left)clipped.left=dirty->left;
  if(dirty->top>clipped.top)clipped.top=dirty->top;
  if(dirty->right<clipped.right)clipped.right=dirty->right;
  if(dirty->bottom<clipped.bottom)clipped.bottom=dirty->bottom;
 }
 if(clipped.left<0)clipped.left=0;
 if(clipped.top<0)clipped.top=0;
 if(clipped.right>(INT)width)clipped.right=width;
 if(clipped.bottom>(INT)height)clipped.bottom=height;
 if(clipped.right<=clipped.left||clipped.bottom<=clipped.top)return;

 dirty_width=clipped.right-clipped.left;
 dirty_height=clipped.bottom-clipped.top;
 row_bytes=(size_t)dirty_width*4u;
 payload_size=row_bytes*dirty_height;
 partial=clipped.left||clipped.top||dirty_width!=width||dirty_height!=height;

 pthread_mutex_lock(&ipc_lock);
 if(connect_ipc_locked())
 {
  connected=TRUE;
  /* A reconnect has a new generation and therefore no host-side baseline for
     any existing HWND. Force the first present of each surface to be full even
     if Wine only dirtied a small rectangle. */
  if(!surface_has_baseline_locked(hwnd)) partial=FALSE;

  if(partial&&payload_size<full_size)
  {
   msg.x=clipped.left;
   msg.y=clipped.top;
   msg.width=dirty_width;
   msg.height=dirty_height;
   msg.stride=row_bytes;
   msg.size=payload_size;
   msg.flags=JUICE_IOS_FRAME_DIRTY;
   success=write_all(ipc_fd,&msg,sizeof(msg));
   /* Avoid allocating/copying a packed dirty-frame buffer while also avoiding
      one write(2) per scanline. writev batches keep stack use bounded. */
   for(start=0;success&&start<dirty_height;start+=count)
   {
    count=dirty_height-start;
    if(count>ARRAY_SIZE(rows)) count=ARRAY_SIZE(rows);
    for(row=0;row<count;row++)
    {
     rows[row].iov_base=(void *)(source+(size_t)(clipped.top+start+row)*stride+
                                 (size_t)clipped.left*4u);
     rows[row].iov_len=row_bytes;
    }
    success=writev_all(ipc_fd,rows,count);
   }
  }
  else
  {
   msg.x=0;
   msg.y=0;
   msg.width=width;
   msg.height=height;
   msg.stride=stride;
   msg.size=full_size;
   msg.flags=0;
   success=write_all(ipc_fd,&msg,sizeof(msg))&&write_all(ipc_fd,bits,full_size);
  }

  if(success) mark_surface_baseline_locked(hwnd);
  else disconnect_ipc_locked();
 }
 pthread_mutex_unlock(&ipc_lock);
 if(connected&&success) ios_ipc_register_queue();
}
