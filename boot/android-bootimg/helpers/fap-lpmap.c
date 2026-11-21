// SPDX-License-Identifier: AGPL-3.0-or-later
/*
 * fap-lpmap: map one logical partition of an Android "super" partition with
 * device-mapper (dm-linear), for tiny-init's fap.root=lp:<name>.
 *
 *   fap-lpmap [-n] [-l <ext4-label>] <super-blockdev> <partition-name>
 *
 * Reads the LP geometry (byte 4096, backup 8192) and the primary metadata
 * of every slot (liblp format, AOSP system/core/fs_mgr/liblp/include/
 * liblp/metadata_format.h), checks every sha256, takes <partition-name>'s
 * linear extents on block device 0 (super itself) from slot 0, refuses if
 * they overlap another partition, leave the device, or if another slot
 * lists different extents. Then creates /dev/mapper/<name> read-write with
 * one linear target per extent (LP and dm sectors are both 512 bytes).
 * -n: dry run (print the table, create nothing); <super> may then be an
 *     image file (e.g. the first MiB of a super backup).
 * -l: after mapping, require an ext4 superblock with this volume label;
 *     on mismatch the mapping is removed again.
 * Exit 0 = mapped (prints "/dev/mapper/<name>"), else a reason on stderr.
 * Never writes to the super device. Static, libc only.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <linux/dm-ioctl.h>

#define LP_GEOMETRY_MAGIC 0x616c4467u
#define LP_METADATA_HEADER_MAGIC 0x414c5030u
#define LP_RESERVED 4096u
#define LP_GEOMETRY_SIZE 4096u
#define LP_TARGET_LINEAR 0
#define MAX_EXT 64

static void die(const char *m) { fprintf(stderr, "fap-lpmap: %s\n", m); exit(1); }

/* ---- sha256 (FIPS 180-4), small and slow is fine ---- */
static const uint32_t K[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha_block(uint32_t h[8], const uint8_t *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, hh, t1, t2;
	int i;
	for (i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4*i] << 24 | p[4*i+1] << 16 | p[4*i+2] << 8 | p[4*i+3];
	for (i = 16; i < 64; i++)
		w[i] = (ROR(w[i-2], 17) ^ ROR(w[i-2], 19) ^ (w[i-2] >> 10)) + w[i-7] +
		       (ROR(w[i-15], 7) ^ ROR(w[i-15], 18) ^ (w[i-15] >> 3)) + w[i-16];
	a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
	for (i = 0; i < 64; i++) {
		t1 = hh + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
		t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}
static void sha256(const uint8_t *data, size_t len, uint8_t out[32])
{
	uint32_t h[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
	uint8_t blk[64];
	size_t i = 0, r;
	uint64_t bits = (uint64_t)len * 8;
	for (; i + 64 <= len; i += 64)
		sha_block(h, data + i);
	r = len - i;
	memset(blk, 0, 64);
	memcpy(blk, data + i, r);
	blk[r] = 0x80;
	if (r >= 56) { sha_block(h, blk); memset(blk, 0, 64); }
	for (i = 0; i < 8; i++)
		blk[63 - i] = (uint8_t)(bits >> (8 * i));
	sha_block(h, blk);
	for (i = 0; i < 8; i++) {
		out[4*i] = h[i] >> 24; out[4*i+1] = h[i] >> 16; out[4*i+2] = h[i] >> 8; out[4*i+3] = h[i];
	}
}

/* ---- little-endian readers ---- */
static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const uint8_t *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }

static void readat(int fd, void *buf, size_t n, uint64_t off)
{
	size_t got = 0;
	while (got < n) {
		ssize_t r = pread(fd, (uint8_t *)buf + got, n - got, (off_t)(off + got));
		if (r <= 0) die("read error on super");
		got += (size_t)r;
	}
}

static int check_sum(uint8_t *buf, size_t len, size_t sum_off)
{
	uint8_t want[32], got[32];
	memcpy(want, buf + sum_off, 32);
	memset(buf + sum_off, 0, 32);
	sha256(buf, len, got);
	memcpy(buf + sum_off, want, 32);
	return memcmp(want, got, 32) == 0;
}

struct ext { uint64_t sectors, phys; };

/*
 * Returns the number of extents of <name> in metadata slot <slot>, -1 if
 * absent (or, with soft, if the slot is unusable: a warning is printed).
 * Strict mode (slot 0) also refuses extents that overlap any other
 * partition's extents.
 */
#define FAIL(...) do { fprintf(stderr, "fap-lpmap: slot %u: ", slot); fprintf(stderr, __VA_ARGS__); \
	fputc('\n', stderr); free(m); if (soft) return -1; exit(1); } while (0)
static int find_part(int fd, uint32_t max_size, uint32_t slot, const char *name, struct ext *ex, int soft)
{
	uint8_t *m = malloc(max_size);
	uint32_t hsize, tsize, poff, pnum, psz, eoff, enum_, esz, i, j, first = 0, cnt = 0;
	int found = 0;
	if (!m) die("out of memory");
	readat(fd, m, max_size, LP_RESERVED + 2 * LP_GEOMETRY_SIZE + (uint64_t)slot * max_size);
	if (le32(m) != LP_METADATA_HEADER_MAGIC) FAIL("bad metadata header");
	hsize = le32(m + 8);
	tsize = le32(m + 44);
	if (hsize < 128 || hsize > 256 || (uint64_t)hsize + tsize > max_size) FAIL("bad metadata header");
	if (!check_sum(m, hsize, 12)) FAIL("header checksum mismatch");
	{
		uint8_t got[32];
		sha256(m + hsize, tsize, got);
		if (memcmp(got, m + 48, 32)) FAIL("tables checksum mismatch");
	}
	poff = le32(m + 80); pnum = le32(m + 84); psz = le32(m + 88);
	eoff = le32(m + 92); enum_ = le32(m + 96); esz = le32(m + 100);
	if (psz < 52 || esz < 24 || (uint64_t)poff + (uint64_t)pnum * psz > tsize ||
	    (uint64_t)eoff + (uint64_t)enum_ * esz > tsize)
		FAIL("metadata tables out of range");
	for (i = 0; i < pnum && !found; i++) {
		const uint8_t *p = m + hsize + poff + (uint64_t)i * psz;
		char pname[37];
		memcpy(pname, p, 36);
		pname[36] = 0;
		if (strcmp(pname, name))
			continue;
		found = 1;
		first = le32(p + 40);
		cnt = le32(p + 44);
	}
	if (!found) { free(m); return -1; }
	if (cnt == 0) FAIL("%s has no extents (size 0)", name);
	if (cnt > MAX_EXT || (uint64_t)first + cnt > enum_) FAIL("bad extent range");
	for (j = 0; j < cnt; j++) {
		const uint8_t *e = m + hsize + eoff + (uint64_t)(first + j) * esz;
		if (le32(e + 8) != LP_TARGET_LINEAR) FAIL("non-linear extent: refusing");
		if (le32(e + 20) != 0) FAIL("extent on another block device: refusing");
		ex[j].sectors = le64(e);
		ex[j].phys = le64(e + 12);
		if (ex[j].sectors == 0 || ex[j].phys + ex[j].sectors < ex[j].phys) FAIL("bad extent");
	}
	if (!soft) {
		/* No overlap with any other extent of this slot (other partitions). */
		for (i = 0; i < enum_; i++) {
			const uint8_t *e = m + hsize + eoff + (uint64_t)i * esz;
			uint64_t s0 = le64(e + 12), n0 = le64(e);
			if (i >= first && i < first + cnt)
				continue;
			if (le32(e + 8) != LP_TARGET_LINEAR || le32(e + 20) != 0)
				continue;
			for (j = 0; j < cnt; j++)
				if (s0 < ex[j].phys + ex[j].sectors && ex[j].phys < s0 + n0)
					FAIL("%s overlaps extent %u of another partition: refusing", name, i);
		}
	}
	free(m);
	return (int)cnt;
}

static void dm_init(struct dm_ioctl *io, size_t size, const char *name)
{
	memset(io, 0, size);
	io->version[0] = DM_VERSION_MAJOR;
	io->version[1] = 0;
	io->version[2] = 0;
	io->data_size = (uint32_t)size;
	io->data_start = sizeof(struct dm_ioctl);
	snprintf(io->name, sizeof io->name, "%s", name);
}

static void dm_remove(int ctl, const char *name)
{
	struct dm_ioctl io;
	dm_init(&io, sizeof io, name);
	ioctl(ctl, DM_DEV_REMOVE, &io);
}

int main(int argc, char **argv)
{
	int dry = 0, fd, ctl, n0, n1, i, opt;
	const char *label = NULL, *dev, *name;
	uint8_t geo[LP_GEOMETRY_SIZE];
	uint32_t max_size, slots, lbs;
	struct ext e0[MAX_EXT], e1[MAX_EXT];
	struct stat st;
	char path[300];

	while ((opt = getopt(argc, argv, "nl:")) != -1) {
		if (opt == 'n') dry = 1;
		else if (opt == 'l') label = optarg;
		else die("usage: fap-lpmap [-n] [-l label] <super> <name>");
	}
	if (argc - optind != 2) die("usage: fap-lpmap [-n] [-l label] <super> <name>");
	dev = argv[optind];
	name = argv[optind + 1];
	if (strlen(name) > 35 || strchr(name, '/')) die("bad partition name");
	if ((fd = open(dev, O_RDONLY | O_CLOEXEC)) < 0) die("cannot open super device");
	if (fstat(fd, &st) || (!S_ISBLK(st.st_mode) && !(dry && S_ISREG(st.st_mode))))
		die("super is not a block device (-n also takes an image file)");

	/* Geometry: primary, else backup. */
	readat(fd, geo, sizeof geo, LP_RESERVED);
	if (le32(geo) != LP_GEOMETRY_MAGIC || le32(geo + 4) < 52 || le32(geo + 4) > sizeof geo ||
	    !check_sum(geo, le32(geo + 4), 8)) {
		readat(fd, geo, sizeof geo, LP_RESERVED + LP_GEOMETRY_SIZE);
		if (le32(geo) != LP_GEOMETRY_MAGIC || le32(geo + 4) < 52 || le32(geo + 4) > sizeof geo ||
		    !check_sum(geo, le32(geo + 4), 8))
			die("no valid LP geometry (not a super partition?)");
	}
	max_size = le32(geo + 40);
	slots = le32(geo + 44);
	lbs = le32(geo + 48);
	if (max_size < 512 || max_size > (1u << 20) || max_size % 512) die("odd metadata_max_size");
	if (slots < 2) die("fewer than 2 metadata slots");
	fprintf(stderr, "fap-lpmap: geometry: metadata %u bytes x %u slots, block %u\n", max_size, slots, lbs);

	/*
	 * Metadata slot 0 is the one the running Android (slot a) maintains and
	 * fastbootd edits; it must have <name>. Other slots: if one lists <name>,
	 * the extents must agree (measured 2026-11-20: slots 1 and 2 of this
	 * unit's super hold a stale, empty table, so absence is only a warning).
	 */
	n0 = find_part(fd, max_size, 0, name, e0, 0);
	if (n0 < 0) {
		fprintf(stderr, "fap-lpmap: %s not in metadata slot 0\n", name);
		return 2;
	}
	{
		uint32_t sl;
		uint64_t end = 0, devsize = 0;
		for (sl = 1; sl < slots && sl < 8; sl++) {
			memset(e1, 0, sizeof e1);
			n1 = find_part(fd, max_size, sl, name, e1, 1);
			if (n1 < 0) {
				fprintf(stderr, "fap-lpmap: note: %s not (validly) in metadata slot %u\n", name, sl);
				continue;
			}
			if (n0 != n1 || memcmp(e0, e1, sizeof(struct ext) * (size_t)n0))
				die("metadata slots disagree on the extents: refusing");
		}
		for (i = 0; i < n0; i++)
			if (e0[i].phys + e0[i].sectors > end)
				end = e0[i].phys + e0[i].sectors;
		if (S_ISBLK(st.st_mode))
			ioctl(fd, BLKGETSIZE64, &devsize);
		else
			devsize = (uint64_t)st.st_size;
		if (S_ISBLK(st.st_mode) && end * 512 > devsize)
			die("extents end beyond the super device: refusing");
	}
	close(fd);

	/* dm table: one linear target per extent. */
	{
		size_t size = sizeof(struct dm_ioctl) + (size_t)n0 * (sizeof(struct dm_target_spec) + 64) + 64;
		struct dm_ioctl *io = calloc(1, size);
		uint8_t *p;
		uint64_t start = 0;
		if (!io) die("out of memory");
		for (i = 0; i < n0; i++) {
			printf("%llu %llu linear %u:%u %llu\n", (unsigned long long)start,
			       (unsigned long long)e0[i].sectors, major(st.st_rdev), minor(st.st_rdev),
			       (unsigned long long)e0[i].phys);
			start += e0[i].sectors;
		}
		fprintf(stderr, "fap-lpmap: %s: %d extent(s), %llu MiB\n", name, n0,
			(unsigned long long)(start >> 11));
		if (dry)
			return 0;

		if ((ctl = open("/dev/mapper/control", O_RDWR | O_CLOEXEC)) < 0 &&
		    (mkdir("/dev/mapper", 0755), mknod("/dev/mapper/control", S_IFCHR | 0600, makedev(10, 236)),
		     (ctl = open("/dev/mapper/control", O_RDWR | O_CLOEXEC)) < 0))
			die("no /dev/mapper/control (CONFIG_BLK_DEV_DM?)");

		dm_init(io, sizeof(struct dm_ioctl), name);
		if (ioctl(ctl, DM_DEV_CREATE, io)) die("DM_DEV_CREATE failed (already mapped?)");

		dm_init(io, size, name);
		io->target_count = (uint32_t)n0;
		p = (uint8_t *)io + sizeof(struct dm_ioctl);
		start = 0;
		for (i = 0; i < n0; i++) {
			struct dm_target_spec *t = (struct dm_target_spec *)p;
			char *params = (char *)(t + 1);
			size_t plen;
			t->sector_start = start;
			t->length = e0[i].sectors;
			snprintf(t->target_type, sizeof t->target_type, "linear");
			snprintf(params, 64, "%u:%u %llu", major(st.st_rdev), minor(st.st_rdev),
				 (unsigned long long)e0[i].phys);
			plen = strlen(params) + 1;
			plen = (plen + 7) & ~(size_t)7;
			t->next = (uint32_t)(sizeof(*t) + plen);
			p += t->next;
			start += e0[i].sectors;
		}
		if (ioctl(ctl, DM_TABLE_LOAD, io)) { dm_remove(ctl, name); die("DM_TABLE_LOAD failed"); }

		dm_init(io, sizeof(struct dm_ioctl), name);
		if (ioctl(ctl, DM_DEV_SUSPEND, io)) { dm_remove(ctl, name); die("resume failed"); }
		snprintf(path, sizeof path, "/dev/mapper/%s", name);
		unlink(path);
		if (mknod(path, S_IFBLK | 0600, (dev_t)io->dev)) { dm_remove(ctl, name); die("mknod failed"); }
		free(io);
	}

	if (label) {
		uint8_t sb[1024];
		char l[17];
		int dfd = open(path, O_RDONLY | O_CLOEXEC);
		if (dfd < 0) { dm_remove(ctl, name); die("cannot open mapped device"); }
		readat(dfd, sb, sizeof sb, 1024);
		close(dfd);
		memcpy(l, sb + 0x78, 16);
		l[16] = 0;
		if (sb[0x38] != 0x53 || sb[0x39] != 0xef || strcmp(l, label)) {
			unlink(path);
			dm_remove(ctl, name);
			fprintf(stderr, "fap-lpmap: %s is not ext4 with label %s: unmapped\n", name, label);
			return 3;
		}
	}
	close(ctl);
	printf("%s\n", path);
	return 0;
}
