#include <poll.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>

int main(int argc, char *argv[]) {
    struct pollfd fds[argc - 1U];
    struct input_event events[32] = { 0 };
    int h, i;
    for(i=1,h=0; i < argc; i++,h++) {
        fds[h].events = POLLIN;
        fds[h].fd = open(argv[i], O_RDONLY);
        if(fds[h].fd < 0) {
            fprintf(stderr, "Skip '%s', error %d, %s...\n", argv[i], errno, strerror(errno));
            h--;
        } else {
            fprintf(stderr, "Poll '%s'...\n", argv[i]);
        }
    }
    if(h == 0) {
        fprintf(stderr, "No useable inputs were given!\n\nUsage: %s /dev/input/eventX...\n", argv[0]);
        exit(3);
    }
    int ret = poll(fds, h, -1);
    if(ret<=0) {
        fprintf(stderr, "Poll error %d, %s...\n", errno, strerror(errno));
        exit(1);
    }
    for(i=1,h=0; i < argc; i++,h++) {
        if(fds[h].revents & POLLIN) {
            usleep(50000);
            h = read(fds[h].fd, events, sizeof(events));

            if(h < 0) {
                fprintf(stderr, "Read error %d, %s...\n", errno, strerror(errno));
                exit(10);
            }

            if(h < sizeof(*events)) {
                fprintf(stderr, "Short read %d bytes, expected %zu...\n", h, sizeof(*events));
            }

            h = h / sizeof(*events);
            for(i=0; i<h; i++) {
                printf("%ld %ld %d %d %d\n", events[i].time.tv_sec, events[i].time.tv_usec, events[i].type, events[i].code, events[i].value);
            }
            exit(0);
        }
    }
    exit(2);
}
