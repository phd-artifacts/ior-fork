/* aiori-ompfile.c – minimal yet complete backend for libompfile
 *
 * Implements the mandatory hooks IOR needs so we no longer segfault in
 * CheckFileSize():
 *   • new OMPFILE_GetFileSize() using fstat on the underlying POSIX file
 *   • wired into the ior_aiori_t descriptor
 *   • descriptor now also provides statfs/mkdir/rmdir/access/stat via the
 *     generic POSIX helpers from aiori.c.
 */

#include "ior.h"
#include "aiori.h"
#include "iordef.h"

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <dlfcn.h>

#include "file_interface.h"  /* libompfile API */

/* ---------------------------------------------------------------------------
 * internal fd wrapper
 * -------------------------------------------------------------------------*/

typedef struct {
    int handle;  /* libompfile file descriptor */
} ompfile_fd_t;

static int ompfile_target_warmup_done = 0;
static int ompfile_target_runtime_initialized = 0;
typedef void (*tgt_rtl_deinit_fn_t)(void);
static tgt_rtl_deinit_fn_t ompfile_tgt_rtl_deinit = NULL;

/* ---------------------------------------------------------------------------
 * small helpers
 * -------------------------------------------------------------------------*/

static void *xmalloc(size_t n)
{
    void *p = malloc(n);
    if (!p) {
        perror("malloc");
        exit(EXIT_FAILURE);
    }
    return p;
}

static int env_enabled(const char *name)
{
    const char *v = getenv(name);
    return v && v[0] == '1' && v[1] == '\0';
}

/* Bootstrap libomptarget/plugin initialization in pure IOR processes before
 * first OMPFILE call. This avoids relying on target-region execution in IOR.
 */
static void OMPFILE_Initialize(aiori_mod_opt_t *opt)
{
    (void)opt;
    if (ompfile_target_warmup_done)
        return;

    if (!(env_enabled("LIBOMPFILE_MPP_OPEN") && env_enabled("LIBOMPFILE_MPP_IO"))) {
        ompfile_target_warmup_done = 1;
        return;
    }

    typedef void (*tgt_rtl_init_fn_t)(void);
    typedef int (*omp_get_num_devices_fn_t)(void);
    void *omptarget_handle = dlopen("libomptarget.so.20.0git",
                                    RTLD_NOW | RTLD_GLOBAL);
    if (!omptarget_handle)
        omptarget_handle = dlopen("libomptarget.so", RTLD_NOW | RTLD_GLOBAL);

    if (!omptarget_handle) {
        fprintf(out_logfile,
                "[ior-mpp] warning: failed to dlopen libomptarget: %s\n",
                dlerror());
        ompfile_target_warmup_done = 1;
        return;
    }

    tgt_rtl_init_fn_t tgt_rtl_init =
        (tgt_rtl_init_fn_t)dlsym(omptarget_handle, "__tgt_rtl_init");
    ompfile_tgt_rtl_deinit =
        (tgt_rtl_deinit_fn_t)dlsym(omptarget_handle, "__tgt_rtl_deinit");

    if (tgt_rtl_init) {
        tgt_rtl_init();
        ompfile_target_runtime_initialized = 1;
    } else {
        fprintf(out_logfile,
                "[ior-mpp] warning: __tgt_rtl_init symbol not found in libomptarget\n");
    }

    omp_get_num_devices_fn_t omp_get_num_devices_fn =
        (omp_get_num_devices_fn_t)dlsym(omptarget_handle, "omp_get_num_devices");
    if (omp_get_num_devices_fn) {
        int num_devices = omp_get_num_devices_fn();
        fprintf(out_logfile,
                "[ior-mpp] libomptarget bootstrap completed devices=%d\n",
                num_devices);
    } else {
        fprintf(out_logfile,
                "[ior-mpp] warning: omp_get_num_devices symbol not found in libomptarget\n");
    }

    ompfile_target_warmup_done = 1;
}

static void OMPFILE_Finalize(aiori_mod_opt_t *opt)
{
    (void)opt;
    if (ompfile_target_runtime_initialized && ompfile_tgt_rtl_deinit)
        ompfile_tgt_rtl_deinit();

    ompfile_target_runtime_initialized = 0;
}

/* ---------------------------------------------------------------------------
 * open / create
 * -------------------------------------------------------------------------*/

static aiori_fd_t *OMPFILE_Open(char *fname, int flags, aiori_mod_opt_t *opt)
{
    (void)opt;  /* unused */

    int h = omp_file_open(fname);
    if (h < 0) {
        /* create path for write phase */
        if (flags & IOR_CREAT) {
            int fd = open(fname, O_CREAT | O_RDWR, 0666);
            if (fd >= 0)
                close(fd);
            h = omp_file_open(fname);
        }
        if (h < 0)
            return NULL; /* IOR will abort */
    }

    ompfile_fd_t *m = xmalloc(sizeof(*m));
    m->handle = h;
    return (aiori_fd_t*)m;
}

static aiori_fd_t *OMPFILE_Create(char *fname, int flags, aiori_mod_opt_t *opt)
{
    flags |= IOR_CREAT;
    return OMPFILE_Open(fname, flags, opt);
}

/* ---------------------------------------------------------------------------
 * xfer (sync only)
 * -------------------------------------------------------------------------*/

static IOR_offset_t OMPFILE_Xfer(int access, aiori_fd_t *fdp, IOR_size_t *buf,
                                IOR_offset_t len, IOR_offset_t off,
                                aiori_mod_opt_t *opt)
{
    (void)opt;
    ompfile_fd_t *m = (ompfile_fd_t*)fdp;

    if (!m)
        return -1;
    assert(m->handle >= 0);

    ssize_t rc;
    if (access == WRITE)
        rc = omp_file_pwrite(m->handle, off, buf, len, 0);
    else
        rc = omp_file_pread (m->handle, off, buf, len, 0);

    return rc < 0 ? rc : len;
}

/* ---------------------------------------------------------------------------
 * close / remove / fsync
 * -------------------------------------------------------------------------*/

static void OMPFILE_Close(aiori_fd_t *fdp, aiori_mod_opt_t *opt)
{
    (void)opt;
    ompfile_fd_t *m = (ompfile_fd_t*)fdp;
    if (m) {
        omp_file_close(m->handle);
        free(m);
    }
}

static void OMPFILE_Fsync(aiori_fd_t *fdp, aiori_mod_opt_t *opt)
{
    (void)opt;
    (void)fdp; /* libompfile lacks fsync; noop */
}

static void OMPFILE_Remove(char *fname, aiori_mod_opt_t *opt)
{
    (void)opt;
    unlink(fname);
}

/* ---------------------------------------------------------------------------
 * file size (needed by IOR CheckFileSize)
 * -------------------------------------------------------------------------*/

static IOR_offset_t OMPFILE_GetFileSize(aiori_mod_opt_t *opt, char *fname)
{
    (void)opt;
    struct stat sb;
    if (stat(fname, &sb) != 0)
        return -1;
    return sb.st_size;
}

/* ---------------------------------------------------------------------------
 * version string
 * -------------------------------------------------------------------------*/

static char *OMPFILE_GetVersion(void)
{
    return "libompfile backend v0.4";
}

/* ---------------------------------------------------------------------------
 * xfer hints unused for now
 * -------------------------------------------------------------------------*/

static void OMPFILE_xfer_hints(aiori_xfer_hint_t *p) { (void)p; }

/* ---------------------------------------------------------------------------
 * AIORI descriptor
 * -------------------------------------------------------------------------*/

ior_aiori_t ompfile_aiori = {
    .name           = "OMPFILE",
    .name_legacy    = NULL,
    .create         = OMPFILE_Create,
    .mknod          = NULL,
    .open           = OMPFILE_Open,
    .xfer_hints     = OMPFILE_xfer_hints,
    .xfer           = OMPFILE_Xfer,
    .close          = OMPFILE_Close,
    .remove         = OMPFILE_Remove,
    .get_version    = OMPFILE_GetVersion,
    .fsync          = OMPFILE_Fsync,
    .get_file_size  = OMPFILE_GetFileSize,
    .statfs         = aiori_posix_statfs,
    .mkdir          = aiori_posix_mkdir,
    .rmdir          = aiori_posix_rmdir,
    .access         = aiori_posix_access,
    .stat           = aiori_posix_stat,
    .initialize     = OMPFILE_Initialize,
    .finalize       = OMPFILE_Finalize,
    .rename         = NULL,
    .get_options    = NULL,
    .check_params   = NULL,
    .sync           = NULL,
    .enable_mdtest  = false
};
