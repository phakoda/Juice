#!/usr/bin/env python3
"""Apply reviewed changes while preserving the concurrent CLI/async-writer work."""
from pathlib import Path
import hashlib, subprocess, sys

def change(path, old, new):
    p=Path(path); text=p.read_text()
    if text.count(old)!=1: raise RuntimeError(f"Review context changed: {path}: {old[:80]}")
    p.write_text(text.replace(old,new))

expected={'app/JuiceDisplayTransportHardening.m': '16824642a4bed07b0032c971ffee40c6a63bee4e96d97285c5585b2866646c8e', 'app/JuiceHostIOHardening.m': '31ea2270bbb40e05accb95af086da5fd897b5e7a8df810936675a3c85d551544', 'app/JuiceAsyncWriter.m': '1e09d0db1038069b558a9b1f1b88e35f4c766702af2cb51879e567adf989a1ba', 'scripts/test-runtime-io-host.sh': 'b7ed354857b1fe37ba17a88d169a40170b5a76337f370ac66cb87d533cc5cee9', 'scripts/verify-mainline-hardening.sh': '9c0784f9809c0c1d0660db7367a554e85d28d56246037fecb1cf1330bbfee2f2', 'scripts/build-app.sh': '78feefde1ce2392081799bf6aadeb387a4bf34deb4a7b21f63dcabf2590c6575'}
for path,digest in expected.items():
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest:
        raise RuntimeError(f"Unreviewed concurrent changes in {path}")
# Reconstruct the reviewed framebuffer delta from its exact original base.
Path('app/JuiceDisplayTransportHardening.m').write_bytes(subprocess.check_output(
    ['git','show',sys.argv[2]+':app/JuiceDisplayTransportHardening.m']))
exclude=['app/JuiceHostIOHardening.m','app/JuiceSocketWriter.h','app/JuiceSocketWriter.m',
         'app/tests/SocketWriterTests.m','scripts/build-app.sh','scripts/verify-mainline-hardening.sh']
args=['git','apply']+['--exclude='+p for p in exclude]
subprocess.run(args+['--check',sys.argv[1]],check=True)
subprocess.run(args+[sys.argv[1]],check=True)
p=Path('app/JuiceDisplayTransportHardening.m')
s=p.read_text().replace('#import "JuiceSocketWriter.h"','#import "JuiceAsyncWriter.h"')
s=s.replace('frame.invalidated=YES;','frame.invalidated=YES;frame.bytes=nil;')
s=s.replace('    JuiceHostInvalidateClient(self,fd);','')
s=s.replace('@synchronized(clients){[clients removeObject:@(fd)];}',
            '@synchronized(clients){[clients removeObject:@(fd)];JuiceCancelDisplayWriter(self,fd);}')
p.write_text(s)
# Keep the shared, globally bounded writer for both sockets and CLI pipes.
change('app/JuiceHostIOHardening.m','#import "JuiceAsyncWriter.h"',
       '#import "JuiceAsyncWriter.h"\n#import "JuiceSocketIO.h"')
p=Path('app/JuiceHostIOHardening.m');s=p.read_text()
a=s.index('static BOOL JuiceReadExact('); b=s.index('static char JuiceHostWritersKey;',a)
s=s[:a]+s[b:]
a=s.index('static void JuiceReadControl('); b=s.index('\n__attribute__',a)
s=s[:a]+'static void JuiceReadControl(id self,SEL _cmd,int fd)\n{\n    (void)_cmd;struct juice_control_message message;\n    if(!JuiceSocketTransferUntil(fd,&message,sizeof(message),0,JuiceSocketNowMS()+5000)||message.magic!=JUICE_CONTROL_MAGIC||message.version!=JUICE_CONTROL_VERSION||message.size!=sizeof(message))\n    {JuiceHostAppend(self,[NSString stringWithFormat:@"CONTROL_V1_PROTOCOL_REJECTED fd=%d\\n",fd]);close(fd);return;}\n    if(message.type==JUICE_CONTROL_IMPORT_REQUEST)\n    {\n        BOOL busy=NO;@synchronized(self)\n        {\n            if([JuiceHostValue(self,@"controlPickerFD") intValue]>=0)busy=YES;\n            else{JuiceHostSetValue(self,@"controlPickerFD",@(fd));JuiceHostSetValue(self,@"controlRequestID",@(message.request_id));JuiceHostSetValue(self,@"controlFilters",@(message.flags));}\n        }\n        if(busy){JuiceReply(self,fd,message.request_id,JUICE_CONTROL_STATUS_ERROR,@"",@"Another Juice import request is already active.");return;}\n        dispatch_async(dispatch_get_main_queue(),^{SEL s=NSSelectorFromString(@"presentControlPicker");if([self respondsToSelector:s])((void(*)(id,SEL))objc_msgSend)(self,s);else\n        {\n            @synchronized(self)\n            {\n                if([JuiceHostValue(self,@"controlPickerFD") intValue]==fd)\n                {\n                    JuiceHostSetValue(self,@"controlPickerFD",@(-1));\n                    JuiceHostSetValue(self,@"controlRequestID",@0);\n                    JuiceHostSetValue(self,@"controlFilters",@0);\n                }\n            }\n            JuiceReply(self,fd,message.request_id,JUICE_CONTROL_STATUS_ERROR,@"",@"The host file picker is unavailable.");\n        }});\n        return;\n    }\n    if(message.type==JUICE_CONTROL_HOST_ACTION)\n    {\n        size_t pathLength=strnlen(message.path,sizeof(message.path));\n        if(pathLength==sizeof(message.path)){close(fd);return;}\n        NSString *path=[[NSString alloc]initWithBytes:message.path length:pathLength encoding:NSUTF8StringEncoding];\n        if(!path){close(fd);return;}\n        uint32_t action=message.flags;close(fd);dispatch_async(dispatch_get_main_queue(),^{SEL s=NSSelectorFromString(@"handleControlAction:path:");if([self respondsToSelector:s])((void(*)(id,SEL,uint32_t,id))objc_msgSend)(self,s,action,path);});return;\n    }\n    close(fd);\n}\n'+s[b:]
p.write_text(s)
change('app/JuiceHostIOHardening.m',
    '    message->size=(uint32_t)payload.length;\n    NSMutableData *packet=[NSMutableData dataWithBytes:message length:sizeof(*message)];',
    '    JuiceHostMsg header=*message;header.size=(uint32_t)payload.length;\n    NSMutableData *packet=[NSMutableData dataWithBytes:&header length:sizeof(header)];')
change('app/JuiceAsyncWriter.m','#import "JuiceIO.h"',
       '#import "JuiceIO.h"\n#import "JuiceSocketIO.h"')
change('app/JuiceAsyncWriter.m','    if (!data.length) return YES;','    if (!data.length) return YES;\n    int64_t now=JuiceSocketNowMS();\n    if(now<0)return NO;\n    const int64_t deadline=now+JUICE_IO_WRITE_TIMEOUT_MS;')
change('app/JuiceAsyncWriter.m','                int result = JuiceWriteWithDeadline(self->_fd, packet.bytes, packet.length,\n                    self->_socket, JUICE_IO_WRITE_TIMEOUT_MS, &self->_cancelled);','                /* Queue residence consumes the same deadline as the syscall. */\n                int64_t current=JuiceSocketNowMS();\n                int64_t remaining=deadline-current;\n                int result;\n                if(current<0)result=-1;\n                else if(remaining<=0){errno=ETIMEDOUT;result=-1;}\n                else result=JuiceWriteWithDeadline(self->_fd,packet.bytes,packet.length,\n                    self->_socket,(unsigned)remaining,&self->_cancelled);')
change('scripts/verify-mainline-hardening.sh',
       "grep -Fq 'errno==EINTR' \"$HOSTIO\"",
       "grep -Fq 'errno == EINTR' \"$ROOT/app/JuiceSocketIO.h\"")
p=Path('scripts/test-host-transport.sh');s=p.read_text()
s=s.replace('CC="${CC:-clang}"','CC="${CC:-clang}"\nextra=()\nif test "$(uname -s)" = Darwin; then extra+=(-D_DARWIN_C_SOURCE); fi')
s=s.replace('"$CC" -std=c11','"$CC" "${extra[@]}" -std=c11')
a=s.index('  "$CC" -fobjc-arc');b=s.index('  "$CC" -fobjc-arc',a+1)
s=s[:a]+s[b:]
s=s.replace('"$ROOT/app/JuiceSocketWriter.m" -framework Foundation -framework CoreGraphics',
            '"$ROOT/app/JuiceAsyncWriter.m" "$WORK/io.o" -framework Foundation -framework CoreGraphics')
s=s.replace('if test "$(uname -s)" = Darwin; then\n  "$CC"',
            'if test "$(uname -s)" = Darwin; then\n  "$CC" -O1 -g -fsanitize=address,undefined -c "$ROOT/app/JuiceIO.c" -o "$WORK/io.o"\n  "$CC"')
p.write_text(s)
p=Path('docs/RUNTIME-HARDENING-VALIDATION-2026-09.md');s=p.read_text()
s=s.replace('bash scripts/test-host-transport.sh\n','bash scripts/test-host-transport.sh\nbash scripts/test-runtime-io-host.sh\n')
s=s.replace('On macOS it additionally\nexercises the actual Foundation socket writer, framebuffer implementation and',
            'The companion `test-runtime-io-host.sh` tests sockets, pipes and the shared\nFoundation writer. On macOS the host tests additionally exercise the framebuffer and')
s=s.replace('to 2 MiB / 1,024 pending messages, and a one-second enqueue-to-write deadline.',
            'to 2 MiB / 512 pending messages, an 8 MiB process-wide queued-byte budget,\nand a two-second enqueue-to-write deadline.')
p.write_text(s)
print('JUICE_REVIEW_RECONCILIATION_OK')
