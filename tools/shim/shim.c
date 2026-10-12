/* R1 sandbox shim (v1): make the file-backed /dev/fb0 behave like a real
 * framebuffer for the ioctls hiby_player needs; everything else passes
 * through. Later versions can also translate evdev records (host 24B vs
 * MIPS 16B) and fake more ioctls.
 *
 * Build: tools/vendors/mipsel-linux-musl-cross/bin/mipsel-linux-musl-gcc \
 *          -shared -static -fPIC -O2 -o shim.so tools/shim/shim.c
 * Inject: qemu-user -E LD_PRELOAD=/hbtools/shim.so  (exposed via a bind)
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <linux/input.h>

void *memset(void *d, int c, size_t n) {
    unsigned char *q = d;
    while (n--)
        *q++ = (unsigned char)c;
    return d;
}

static long sys_ioctl(long fd, unsigned long req, void *p) {
    return syscall(54, fd, req, p, 0);
}

int ioctl(int fd, int request, ...);
int ioctl(int fd, int request, ...) {
    va_list ap;
    va_start(ap, request);
    void *argp = va_arg(ap, void *);
    va_end(ap);

    if (!argp)
        return (int)sys_ioctl(fd, request, 0);

    switch (request) {
    case FBIOGET_FSCREENINFO: {
        struct fb_fix_screeninfo *f = argp;
        memset(f, 0, sizeof(*f));
        f->id[0] = 'R'; f->id[1] = '1';
        f->type = FB_TYPE_PACKED_PIXELS;
        f->visual = FB_VISUAL_TRUECOLOR;
        f->line_length = 480 * 2;
        f->smem_len = 480 * 800 * 2;
        return 0;
    }
    case FBIOGET_VSCREENINFO: {
        struct fb_var_screeninfo *v = argp;
        memset(v, 0, sizeof(*v));
        v->xres = 480; v->yres = 800;
        v->xres_virtual = 480; v->yres_virtual = 800;
        v->bits_per_pixel = 16;
        v->red.offset = 11; v->red.length = 5;  v->red.msb_right = 0;
        v->green.offset = 5; v->green.length = 6; v->green.msb_right = 0;
        v->blue.offset = 0;  v->blue.length = 5;  v->blue.msb_right = 0;
        v->pixclock = 40000000;
        v->vmode = FB_VMODE_NONINTERLACED;
        return 0;
    }
    case FBIOGET_CON2FBMAP: {
        unsigned char *b = argp;
        b[0] = 0; b[1] = 0;
        return 0;
    }
    /* ---- evdev fake ident: version/id/name/type bits ---- */
    case EVIOCGVERSION:
        *(int *)argp = 0x010001;
        return 0;
    case EVIOCGID: {
        struct input_id *id = argp;
        memset(id, 0, sizeof(*id));
        id->bustype = BUS_VIRTUAL;
        id->vendor = 0x4842; /* "HB" */
        id->product = 1;
        return 0;
    }
    default: {
        /* variable-size EVIOCGNAME / EVIOCGBIT: passed dir 'E' 0x06/0x20x */
        int type  = (request >> 8) & 0xff;
        int nr    = request & 0xff;
        int size  = (request >> 16) & 0x3fff;
        if ((request >> 30) == 2 && type == 'E') {  /* _IOC_READ on mips */
            memset(argp, 0, size);
            if (nr == 0x06) {                       /* EVIOCGNAME */
                const char *n = "HiBy R1 sandbox";
                size_t i;
                for (i = 0; n[i] && (int)i < size - 1; i++)
                    ((char *)argp)[i] = n[i];
                return 0;
            }
            if (nr == 0x20) {                       /* EVIOCGBIT */
                ((unsigned char *)argp)[0] = (1 << EV_SYN) | (1 << EV_KEY)
                                           | (1 << EV_ABS);
                return 0;
            }
            return 0;   /* positive-empty: benign */
        }
        return sys_ioctl(fd, request, argp);
    }
}
}
