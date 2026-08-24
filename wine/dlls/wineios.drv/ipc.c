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
#include <sys/un.h>
#include <unistd.h>
#include "ipc.h"
#include "wine/server.h"
WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);
static int ipc_fd=-1; static pthread_mutex_t ipc_lock=PTHREAD_MUTEX_INITIALIZER;
static __thread BOOL queue_registered;
static HWND input_target;
static BOOL pointer_down;
static BOOL write_all(int fd,const void *data,size_t size){const char *p=data;while(size){ssize_t n=write(fd,p,size);if(n<0&&errno==EINTR)continue;if(n<=0)return FALSE;p+=n;size-=n;}return TRUE;}
static BOOL read_all(int fd,void *data,size_t size){char *p=data;while(size){ssize_t n=read(fd,p,size);if(n<0&&errno==EINTR)continue;if(n<=0)return FALSE;p+=n;size-=n;}return TRUE;}
static void disconnect_ipc_locked(void){if(ipc_fd>=0)close(ipc_fd);ipc_fd=-1;queue_registered=FALSE;}
static void send_msg(UINT type,HWND hwnd,const RECT *rect,const void *payload,UINT size,UINT stride,UINT flags)
{
 struct juice_ios_msg msg={JUICE_IOS_MAGIC,type,size,(UINT64)(UINT_PTR)hwnd};
 if(rect){msg.x=rect->left;msg.y=rect->top;msg.width=rect->right-rect->left;msg.height=rect->bottom-rect->top;} msg.stride=stride;msg.flags=flags;
 pthread_mutex_lock(&ipc_lock);if(ipc_fd>=0&&(!write_all(ipc_fd,&msg,sizeof(msg))||(size&&!write_all(ipc_fd,payload,size))))disconnect_ipc_locked();pthread_mutex_unlock(&ipc_lock);
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

  if(ipc_fd<0) break;
  available=recv(ipc_fd,&msg,sizeof(msg),MSG_PEEK|MSG_DONTWAIT);
  if(available<(ssize_t)sizeof(msg)) break;
  if(!read_all(ipc_fd,&msg,sizeof(msg)))
  {
   pthread_mutex_lock(&ipc_lock);disconnect_ipc_locked();pthread_mutex_unlock(&ipc_lock);
   break;
  }
  if(msg.size>64u*1024u)
  {
   fprintf(stderr,"[JuiceInput] rejected oversized message type=%u size=%u\n",msg.type,msg.size);
   pthread_mutex_lock(&ipc_lock);disconnect_ipc_locked();pthread_mutex_unlock(&ipc_lock);
   break;
  }
  if(msg.size)
  {
   payload=malloc(msg.size);
   if(!payload||!read_all(ipc_fd,payload,msg.size))
   {
    free(payload);
    pthread_mutex_lock(&ipc_lock);disconnect_ipc_locked();pthread_mutex_unlock(&ipc_lock);
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
   target=input_target?input_target:hwnd;
   NtUserSetForegroundWindow(hwnd);
   NtUserSetActiveWindow(hwnd);
   NtUserSetFocus(target);
   NtUserMessageCall(target,WM_CHAR,msg.flags&0xffffu,1,NULL,NtUserSendMessage,FALSE);
   sent=1;
   text_length=NtUserMessageCall(target,WM_GETTEXTLENGTH,0,0,NULL,NtUserSendMessage,FALSE);
   redrawn=NtUserRedrawWindow(target,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   redrawn|=NtUserRedrawWindow(hwnd,NULL,0,RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
   presented=iosdrv_present_now(hwnd);
   fprintf(stderr,"[JuiceInput] key surface=%p target=%p vk=%x delivered=%u length=%ld redraw=%u present=%u\n",hwnd,target,msg.flags&0xffffu,sent,(long)text_length,redrawn,presented);
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
 int ret;

 if(queue_registered||ipc_fd<0) return;
 if(wine_server_fd_to_handle(ipc_fd,GENERIC_READ|SYNCHRONIZE,0,&handle))
 {
  fprintf(stderr,"[JuiceInput] failed to allocate queue fd handle tid=%p\n",NtCurrentTeb()->ClientId.UniqueThread);
  return;
 }
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
  queue_registered=TRUE;
  fprintf(stderr,"[JuiceInput] queue fd registered fd=%d tid=%p\n",ipc_fd,NtCurrentTeb()->ClientId.UniqueThread);
 }
}
void ios_ipc_init(unsigned int width,unsigned int height,unsigned int dpi)
{
 const char *path=getenv("JUICE_IOS_SOCKET");
 struct sockaddr_un addr;
 struct juice_ios_msg hello={JUICE_IOS_MAGIC,JUICE_IOS_HELLO,0,0,0,0,(INT)width,(INT)height,dpi,(UINT)getpid()};
 int one=1;

 if(!path||!*path) return;
 memset(&addr,0,sizeof(addr));
 addr.sun_family=AF_UNIX;
 if(strlen(path)>=sizeof(addr.sun_path)) return;
 strcpy(addr.sun_path,path);
 ipc_fd=socket(AF_UNIX,SOCK_STREAM,0);
 if(ipc_fd<0) return;
#ifdef SO_NOSIGPIPE
 setsockopt(ipc_fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#else
 (void)one;
#endif
 if(connect(ipc_fd,(struct sockaddr *)&addr,sizeof(addr))<0)
 {
  close(ipc_fd);
  ipc_fd=-1;
  return;
 }
 if(!write_all(ipc_fd,&hello,sizeof(hello)))
 {
  close(ipc_fd);
  ipc_fd=-1;
  return;
 }
 ios_ipc_register_queue();
}
void ios_ipc_window(HWND hwnd,const RECT *rect,BOOL visible){send_msg(JUICE_IOS_WINDOW,hwnd,rect,NULL,0,0,visible);}
void ios_ipc_destroy(HWND hwnd){send_msg(JUICE_IOS_DESTROY,hwnd,NULL,NULL,0,0,0);}
void ios_ipc_present(HWND hwnd,const void *bits,unsigned int width,unsigned int height,unsigned int stride,const RECT *dirty)
{
 struct juice_ios_msg msg={JUICE_IOS_MAGIC,JUICE_IOS_FRAME,0,(UINT64)(UINT_PTR)hwnd};
 const unsigned char *source=bits;
 unsigned char *packed=NULL;
 size_t full_size,payload_size,row_bytes;
 unsigned int dirty_width,dirty_height,row;
 RECT clipped;
 BOOL partial=FALSE;

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

 /* Full frames are cheaper as a single contiguous write. For partial frames,
  * packing rows costs one memcpy per row but avoids transmitting untouched
  * pixels and keeps the receiver protocol simple. */
 partial=clipped.left||clipped.top||dirty_width!=width||dirty_height!=height;
 if(partial&&payload_size<full_size)
 {
  packed=malloc(payload_size);
  if(packed)
  {
   for(row=0;row<dirty_height;row++)
    memcpy(packed+(size_t)row*row_bytes,
           source+(size_t)(clipped.top+row)*stride+(size_t)clipped.left*4u,
           row_bytes);
   source=packed;
   msg.x=clipped.left;
   msg.y=clipped.top;
   msg.width=dirty_width;
   msg.height=dirty_height;
   msg.stride=row_bytes;
   msg.size=payload_size;
   msg.flags=JUICE_IOS_FRAME_DIRTY;
  }
  else partial=FALSE;
 }

 if(!partial||!packed)
 {
  source=bits;
  msg.x=0;
  msg.y=0;
  msg.width=width;
  msg.height=height;
  msg.stride=stride;
  msg.size=full_size;
  msg.flags=0;
 }

 pthread_mutex_lock(&ipc_lock);
 if(ipc_fd>=0&&(!write_all(ipc_fd,&msg,sizeof(msg))||!write_all(ipc_fd,source,msg.size)))disconnect_ipc_locked();
 pthread_mutex_unlock(&ipc_lock);
 free(packed);
}
