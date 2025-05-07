/* aiori-ompfile.c – minimal IOR backend using libompfile
 *
 * CHANGE‑LOG v0.3 (fix segfault on first write)
 *   • Added **sanity checks** for all incoming pointers/lengths.
 *   • If pwrite/pread return <0, fall back to seek+write/read path.
 *   • Added optional initial seek(0) on create to guarantee the
 *     internal file offset is valid before the first I/O.
 *   • Implemented a dummy remove() using POSIX unlink so IOR can
 *     delete the file after the run.
 *
 * NOTE: libompfile currently exposes only synchronous routines.  We
 *       ignore the ‘async’ flag for now but keep it in the call.
 */

#include "ior.h"
#include "aiori.h"
#include "iordef.h"

#include "file_interface.h"   /* libompfile public header */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define ERRF(fmt, ...)                                                    \
    do { fprintf(stderr, "[OMPFILE] " fmt "\n", ##__VA_ARGS__);          \
         MPI_Abort(MPI_COMM_WORLD, -1); } while (0)

/* ----------------------------------------------------------------- */
typedef struct {
    int fh;             /* opaque handle from libompfile */
} ompfile_fd_t;

static aiori_xfer_hint_t *hints = NULL;
static void OMPFILE_xfer_hints(aiori_xfer_hint_t *p) { hints = p; }

/* ----------------------------------------------------------------- */
static ompfile_fd_t *alloc_fd(int fh)
{
    ompfile_fd_t *p = malloc(sizeof(*p));
    if (!p) ERRF("malloc failed");
    p->fh = fh;
    return p;
}

static ompfile_fd_t *open_with_create(const char *path, int iorflags)
{
    int fh = omp_file_open(path);

    if (fh < 0 && (iorflags & IOR_CREAT)) {
        /* Ensure the file exists, then retry. */
        int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0666);
        if (fd >= 0) close(fd);
        fh = omp_file_open(path);
    }

    if (fh < 0) {
        ERRF("omp_file_open failed for %s (flags=0x%x)", path, iorflags);
    }

    /* libompfile starts with offset 0 but to be extra safe: */
    if (omp_file_seek(fh, 0) < 0)
        ERRF("omp_file_seek(0) failed for %s", path);

    return alloc_fd(fh);
}

static aiori_fd_t *OMPFILE_Create(char *fname, int flags, aiori_mod_opt_t *o)
{ return (aiori_fd_t *)open_with_create(fname, flags | IOR_CREAT | IOR_TRUNC); }

static aiori_fd_t *OMPFILE_Open(char *fname, int flags, aiori_mod_opt_t *o)
{ return (aiori_fd_t *)open_with_create(fname, flags); }

/* ----------------------------------------------------------------- */
static IOR_offset_t OMPFILE_Xfer(int access, aiori_fd_t *fdp,
                                 IOR_size_t *buf,
                                 IOR_offset_t len, IOR_offset_t off,
                                 aiori_mod_opt_t *o)
{
    if (!fdp || !buf || len <= 0) ERRF("invalid args to Xfer");

    ompfile_fd_t *p = (ompfile_fd_t *)fdp;
    int async = 0;
    int rc;

    long loff = (long)off; /* lib accepts long */

    if (access == WRITE)
        rc = omp_file_pwrite(p->fh, loff, buf, (size_t)len, async);
    else
        rc = omp_file_pread(p->fh, loff, buf, (size_t)len, async);

    /* Fallback path if p*write/p*read unsupported */
    if (rc < 0) {
        if (omp_file_seek(p->fh, loff) < 0)
            ERRF("seek fallback failed at %ld", loff);
        if (access == WRITE)
            rc = omp_file_write(p->fh, buf, (size_t)len, async);
        else
            rc = omp_file_read(p->fh, buf, (size_t)len, async);
    }

    if (rc < 0)
        ERRF("omp_file_%s failed (off=%ld, len=%lld)",
              access == WRITE ? "write" : "read", loff, (long long)len);

    return len; /* bytes transferred equals requested length */
}

/* ----------------------------------------------------------------- */
static void OMPFILE_Fsync(aiori_fd_t *fdp, aiori_mod_opt_t *o)
{ /* no explicit fsync in libompfile yet */ }

static void OMPFILE_Close(aiori_fd_t *fdp, aiori_mod_opt_t *o)
{
    if (!fdp) return;
    ompfile_fd_t *p = (ompfile_fd_t *)fdp;
    omp_file_close(p->fh);
    free(p);
}

static void OMPFILE_Remove(char *fname, aiori_mod_opt_t *o)
{
    unlink(fname); /* simple POSIX remove */
}

static char *OMPFILE_GetVersion(void)
{
    static char ver[] = "libompfile backend v0.3";
    return ver;
}

/* ----------------------------------------------------------------- */
ior_aiori_t ompfile_aiori = {
    .name            = "OMPFILE",
    .name_legacy     = NULL,
    .create          = OMPFILE_Create,
    .get_options     = NULL,
    .xfer_hints      = OMPFILE_xfer_hints,
    .open            = OMPFILE_Open,
    .xfer            = OMPFILE_Xfer,
    .close           = OMPFILE_Close,
    .remove          = OMPFILE_Remove,
    .get_version     = OMPFILE_GetVersion,
    .fsync           = OMPFILE_Fsync,
    .get_file_size   = NULL,
    .statfs          = aiori_posix_statfs,
    .mkdir           = aiori_posix_mkdir,
    .rmdir           = aiori_posix_rmdir,
    .access          = aiori_posix_access,
    .stat            = aiori_posix_stat,
    .check_params    = NULL,
    .enable_mdtest   = false
};
