// File: src/aiori/aiori-OMPFile.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "aiori.h"
#include "IOR.h"

// Include your C header for the omp_file_* interface
#ifdef __cplusplus
extern "C" {
#endif

int omp_file_open(const char *filename);
int omp_file_close(int file_handle);
int omp_file_write(int file_handle, const void *data, size_t size, int async);
int omp_file_read(int file_handle, void *data, size_t size, int async);
int omp_file_pwrite(int file_handle, long offset, const void *data, size_t size, int async);
int omp_file_pread(int file_handle, long offset, void *data, size_t size, int async);
int omp_file_seek(int file_handle, long offset);

#ifdef __cplusplus
}
#endif

static int file_handle = -1;

// Basic Open function
IOR_offset_t OMPFile_Open(FIL **fd, const char *testFileName, IOR_param_t *param) {
    file_handle = omp_file_open(testFileName);
    return (file_handle >= 0) ? 0 : -1;
}

IOR_offset_t OMPFile_Close(FIL **fd, IOR_param_t *param) {
    return omp_file_close(file_handle);
}

IOR_offset_t OMPFile_Write(FIL **fd, void *buffer, IOR_size_t length, IOR_offset_t *offset, IOR_param_t *param) {
    if (offset && param->useFileView == FALSE) {
        omp_file_seek(file_handle, *offset);
    }
    return omp_file_write(file_handle, buffer, length, 0);
}

IOR_offset_t OMPFile_Read(FIL **fd, void *buffer, IOR_size_t length, IOR_offset_t *offset, IOR_param_t *param) {
    if (offset && param->useFileView == FALSE) {
        omp_file_seek(file_handle, *offset);
    }
    return omp_file_read(file_handle, buffer, length, 0);
}

IOR_offset_t OMPFile_Check(FIL **fd, IOR_param_t *param) {
    // Not implemented
    return 0;
}

IOR_offset_t OMPFile_Delete(const char *testFileName) {
    return unlink(testFileName);
}

void OMPFile_SetVersion(IOR_param_t *param) {
    // optional stub
}

const char *OMPFile_GetVersion(void) {
    return "OMPFileIO v0.1";
}

// Register interface
aiori_t aiori_OMPFile = {
    .name = "OMPFile",
    .Open = OMPFile_Open,
    .Close = OMPFile_Close,
    .Read = OMPFile_Read,
    .Write = OMPFile_Write,
    .Check = OMPFile_Check,
    .Delete = OMPFile_Delete,
    .SetVersion = OMPFile_SetVersion,
    .GetVersion = OMPFile_GetVersion
};
