// SPDX-License-Identifier: MIT
// CUPS transport client. Bluetooth is owned by the user's permission-bearing app.
#include "IPC.h"
#include <cups/backend.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pwd.h>
#include <poll.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

static volatile sig_atomic_t canceled=0;
static void cancelJob(int signalNumber) {(void)signalNumber;canceled=1;}
static double uptime(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int transfer(int fd,void *buffer,size_t size,int writing,double deadline) {
    size_t pos=0;
    while(pos<size && !canceled && uptime()<deadline) {
        struct pollfd p={fd,writing?POLLOUT:POLLIN,0};int ready=poll(&p,1,250);
        if(ready<0) continue;if(!ready) continue;
        ssize_t n=writing?write(fd,(char *)buffer+pos,size-pos):read(fd,(char *)buffer+pos,size-pos);
        if(n<0 && (errno==EAGAIN || errno==EINTR)) continue;
        if(n<=0) return 0;pos+=(size_t)n;
    }
    return pos==size;
}
int main(int argc,char **argv) {
    if(argc==1) {puts("direct rw403bble \"MUNBYN RW403B Bluetooth LE\" \"RW403B Bluetooth LE\"");return 0;}
    if(argc!=6 && argc!=7) return CUPS_BACKEND_CANCEL;
    const char *uri=cupsBackendDeviceURI(argv);
    if(!uri || strcmp(uri,RW_URI)) {fputs("ERROR: Printer URI does not match the selected RW403B\n",stderr);return CUPS_BACKEND_CANCEL;}
    char *end;long copies=strtol(argv[4],&end,10);
    if(!*argv[4] || *end || copies<1 || copies>20) return CUPS_BACKEND_CANCEL;
    signal(SIGPIPE,SIG_IGN);signal(SIGTERM,cancelJob);
    int input=argc==7?open(argv[6],O_RDONLY|O_NOFOLLOW):STDIN_FILENO;
    if(input<0) return CUPS_BACKEND_CANCEL;
    unsigned char *data=malloc(RW_MAX_BYTES+1);if(!data) return CUPS_BACKEND_HOLD;
    size_t size=0;double deadline=uptime()+90;int invalid=0;
    for(;;) {
        if(canceled || uptime()>deadline) {invalid=1;break;}
        struct pollfd p={input,POLLIN,0};if(poll(&p,1,250)<=0) continue;
        ssize_t n=read(input,data+size,RW_MAX_BYTES+1-size);
        if(n<0) {invalid=1;break;}if(!n) break;size+=(size_t)n;
        if(size>RW_MAX_BYTES) {invalid=1;break;}
    }
    if(argc==7) close(input);
    if(invalid || size<4 || (memcmp(data,"3SaR",4)&&memcmp(data,"RaS3",4))) {
        free(data);fputs("ERROR: Invalid, canceled or oversized raster input\n",stderr);return CUPS_BACKEND_CANCEL;
    }
    struct sockaddr_un address={0};address.sun_family=AF_UNIX;
    if(strlcpy(address.sun_path,RW_SOCKET_PATH,sizeof address.sun_path)>=sizeof address.sun_path) {free(data);return CUPS_BACKEND_HOLD;}
    int fd=socket(AF_UNIX,SOCK_STREAM,0);int yes=1;
    if(fd<0) {free(data);return CUPS_BACKEND_HOLD;}
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof yes);
    if(connect(fd,(struct sockaddr *)&address,sizeof address)) {
        fprintf(stderr,"ERROR: Local printer connection: %s\n",strerror(errno));
        fputs("ERROR: Open the RW403B Bluetooth app in your login session, then review and resume this held job. No print data was sent.\n",stderr);
        free(data);close(fd);return CUPS_BACKEND_HOLD;
    }
    uid_t uid;gid_t gid;
    if(getpeereid(fd,&uid,&gid) || uid!=RW_USER_ID) {free(data);close(fd);return CUPS_BACKEND_HOLD;}
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);
    uint32_t header[]={htonl(0x52574231),htonl((uint32_t)size),htonl((uint32_t)copies)};
    deadline=uptime()+600;
    int sent=transfer(fd,header,sizeof header,1,deadline) && transfer(fd,data,size,1,deadline);free(data);
    fputs("INFO: Waiting for the RW403B app and printer to finish\n",stderr);
    uint32_t reply;int received=sent && transfer(fd,&reply,sizeof reply,0,deadline);
    if(canceled) {write(fd,"C",1);close(fd);return CUPS_BACKEND_CANCEL;}
    close(fd);
    if(!received) {fputs("ERROR: Printer app disconnected or timed out; output may be partial. Review the printer before retrying.\n",stderr);return CUPS_BACKEND_HOLD;}
    unsigned result=ntohl(reply);
    if(result==0) fputs("INFO: Printer acknowledged all sections and reported completion\n",stderr);
    else fputs("ERROR: RW403B app reported failure or cancellation; inspect its log before retrying\n",stderr);
    return result==0?CUPS_BACKEND_OK:(result==CUPS_BACKEND_CANCEL?CUPS_BACKEND_CANCEL:CUPS_BACKEND_HOLD);
}
