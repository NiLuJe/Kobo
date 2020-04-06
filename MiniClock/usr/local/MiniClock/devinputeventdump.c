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
    if(argc - 1U > 2) {
        fprintf(stderr, "Can't poll more than 2 input devices!\n");
        exit(3);
    }

    struct pollfd fds[2] = { 0 };
    struct input_event events[32] = { 0 };
    int h = 0;
    for(int i=1; i < argc; i++,h++) {
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
    h = 0;
    for(int i=1; i < argc; i++,h++) {
        if(fds[h].revents & POLLIN) {
            usleep(50000);
            ssize_t b = read(fds[h].fd, events, sizeof(events));

            if(b < 0) {
                fprintf(stderr, "Read error %d, %s...\n", errno, strerror(errno));
                exit(10);
            }

            if((size_t) b < sizeof(*events)) {
                fprintf(stderr, "Short read %zd bytes, expected %zu...\n", b, sizeof(*events));
            }

            h = b / sizeof(*events);
            for(int j=0; j<h; j++) {
                printf("%ld %ld %d %d %d\n", events[j].time.tv_sec, events[j].time.tv_usec, events[j].type, events[j].code, events[j].value);
            }
            exit(0);
        }
    }
    exit(2);
}
