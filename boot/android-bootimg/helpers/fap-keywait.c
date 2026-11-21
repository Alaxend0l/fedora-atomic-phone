// SPDX-License-Identifier: AGPL-3.0-or-later
/*
 * fap-keywait: wait for a volume key on any /dev/input/event* (boot menu in
 * tiny-init). Prints "up", "down" or "timeout".
 *
 *   fap-keywait <seconds>      (0 = wait forever)
 *
 * A key that is already held when it starts (stuck key, or the user still
 * holding a volume key from the bootloader) is ignored until released.
 * Static, libc only; reads input events, writes nothing.
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAXDEV 32

int main(int argc, char **argv)
{
	struct pollfd pf[MAXDEV];
	int held[MAXDEV][2];
	int n = 0, i, secs = argc > 1 ? atoi(argv[1]) : 3;
	struct timespec t0, now;
	DIR *d = opendir("/dev/input");
	struct dirent *de;

	if (!d) { puts("timeout"); return 1; }
	while ((de = readdir(d)) && n < MAXDEV) {
		char p[300];
		unsigned char keys[KEY_MAX / 8 + 1];
		if (strncmp(de->d_name, "event", 5))
			continue;
		snprintf(p, sizeof p, "/dev/input/%s", de->d_name);
		pf[n].fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (pf[n].fd < 0)
			continue;
		pf[n].events = POLLIN;
		memset(keys, 0, sizeof keys);
		ioctl(pf[n].fd, EVIOCGKEY(sizeof keys), keys);
		held[n][0] = !!(keys[KEY_VOLUMEUP / 8] & (1 << (KEY_VOLUMEUP % 8)));
		held[n][1] = !!(keys[KEY_VOLUMEDOWN / 8] & (1 << (KEY_VOLUMEDOWN % 8)));
		n++;
	}
	closedir(d);
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (;;) {
		int left = -1;
		if (secs > 0) {
			clock_gettime(CLOCK_MONOTONIC, &now);
			left = secs * 1000 - (int)((now.tv_sec - t0.tv_sec) * 1000 +
						   (now.tv_nsec - t0.tv_nsec) / 1000000);
			if (left <= 0)
				break;
		}
		if (n == 0) {
			if (left < 0) { sleep(1); continue; }
			usleep((useconds_t)left * 1000);
			break;
		}
		if (poll(pf, (nfds_t)n, left) <= 0)
			continue;
		for (i = 0; i < n; i++) {
			struct input_event ev;
			while (read(pf[i].fd, &ev, sizeof ev) == (ssize_t)sizeof ev) {
				int k;
				if (ev.type != EV_KEY)
					continue;
				k = ev.code == KEY_VOLUMEUP ? 0 : ev.code == KEY_VOLUMEDOWN ? 1 : -1;
				if (k < 0)
					continue;
				if (ev.value == 0) { held[i][k] = 0; continue; }
				if (ev.value == 1 && !held[i][k]) {
					puts(k == 0 ? "up" : "down");
					return 0;
				}
			}
		}
	}
	puts("timeout");
	return 0;
}
