/* aiori-ompfile.c - minimal IOR backend that uses libompfile
 *
 * This *initial skeleton* wires IOR’s abstract interface to the
 * synchronous calls exported by libompfile.so (see file_interface.h).
 * The goal is to get something that compiles, links and can be
 * exercised with small read/write tests before we flesh out advanced
 * features (async I/O, views, options, etc.).
 */

#include "ior.h"
#include "aiori.h"
#include "iordef.h"
#include "utilities.h"

#include "file_interface.h"   /* libompfile */

/**************************  P R O T O T Y P E S  ***************************/
static aiori_fd_t *OMPFILE_Create(char *path, int flags, aiori_mod_opt_t *);
static aiori_fd_t *OMPFILE_Open  (char *path, int flags, aiori_mod_opt_t *);
static IOR_offset_t OMPFILE_Xfer(int access, aiori_fd_t *fdp, IOR_size_t *buf,
                                IOR_offset_t len, IOR_offset_t off,
                                aiori_mod_opt_t *);
static void OMPFILE_Close(aiori_fd_t *fdp, aiori_mod_opt_t *);
static void OMPFILE_Fsync(aiori_fd_t *fdp, aiori_mod_opt_t *);
static char *OMPFILE_GetVersion(void);
static int  OMPFILE_check_params(aiori_mod_opt_t *);
static option_help *OMPFILE_options(aiori_mod_opt_t **, aiori_mod_opt_t *);
static void OMPFILE_xfer_hints(aiori_xfer_hint_t *);

/**************************  I O R   H O O K S  *****************************/
ior_aiori_t ompfile_aiori = {
    .name          = "OMPFILE",
    .create        = OMPFILE_Create,
    .open          = OMPFILE_Open,
    .xfer          = OMPFILE_Xfer,
    .close         = OMPFILE_Close,
    .remove        = NULL,          /* will piggy‑back POSIX_Delete later */
    .xfer_hints    = OMPFILE_xfer_hints,
    .get_version   = OMPFILE_GetVersion,
    .fsync         = OMPFILE_Fsync,
    .get_file_size = NULL,          /* TODO */
    .get_options   = OMPFILE_options,
    .check_params  = OMPFILE_check_params
};

/**************************  L O C A L   D A T A  ***************************/
/* Very first step: we don’t expose backend‑specific CLI options.           */
typedef struct { int dummy; } ompfile_options_t;
static aiori_xfer_hint_t *hints = NULL;

/**************************  H E L P E R S  *********************************/
typedef struct {
    int handle; /* returned by libompfile */
} ompfile_fd_t;

/**************************  O P T I O N S  *********************************/
static option_help *OMPFILE_options(aiori_mod_opt_t **out, aiori_mod_opt_t *init)
{
    /* No custom options yet – allocate & zero so we have something to store */
    ompfile_options_t *o = malloc(sizeof(*o));
    memset(o, 0, sizeof(*o));
    *out = (aiori_mod_opt_t *)o;

    static option_help table[] = { LAST_OPTION };
    return table;
}

static int OMPFILE_check_params(aiori_mod_opt_t *opts)
{
    (void)opts; /* nothing to check for now */
    return 0;
}

static void OMPFILE_xfer_hints(aiori_xfer_hint_t *p){ hints = p; }

/**************************  C R E A T E / O P E N  *************************/
static aiori_fd_t *OMPFILE_Create(char *path, int flags, aiori_mod_opt_t *opts)
{
    /* For the first iteration we ignore flags and just call Open().
     * libompfile currently only supports "open" with filename.
     */
    return OMPFILE_Open(path, flags, opts);
}

static aiori_fd_t *OMPFILE_Open(char *path, int flags, aiori_mod_opt_t *opts)
{
    (void)flags; (void)opts; /* unused for now */

    ompfile_fd_t *m = malloc(sizeof(*m));
    if(!m) ERR("malloc failed");

    m->handle = omp_file_open(path);
    if(m->handle < 0)
        ERRF("omp_file_open failed for %s", path);

    return (aiori_fd_t*)m;
}

/**************************  X F E R  ****************************************/
static IOR_offset_t OMPFILE_Xfer(int access, aiori_fd_t *fdp, IOR_size_t *buf,
                                IOR_offset_t len, IOR_offset_t off,
                                aiori_mod_opt_t *opts)
{
    (void)opts; /* no backend options yet */
    ompfile_fd_t *m = (ompfile_fd_t*)fdp;
    int rc;

    if(access == WRITE){
        rc = omp_file_pwrite(m->handle, off, buf, (size_t)len, /*async=*/0);
    }else{
        rc = omp_file_pread (m->handle, off, buf, (size_t)len, /*async=*/0);
    }
    if(rc < 0)
        ERR("omp_file_[p]read/write failed");
    return len; /* assume full xfer for now */
}

/**************************  F S Y N C  **************************************/
static void OMPFILE_Fsync(aiori_fd_t *fdp, aiori_mod_opt_t *opts)
{
    (void)fdp; (void)opts; /* libompfile currently has no fsync – NOP */
}

/**************************  C L O S E  **************************************/
static void OMPFILE_Close(aiori_fd_t *fdp, aiori_mod_opt_t *opts)
{
    (void)opts;
    ompfile_fd_t *m = (ompfile_fd_t*)fdp;
    if(omp_file_close(m->handle) < 0)
        WARN("omp_file_close failed");
    free(m);
}

/**************************  V E R S I O N  **********************************/
static char *OMPFILE_GetVersion(void)
{
    return "(libompfile minimal)";
}
