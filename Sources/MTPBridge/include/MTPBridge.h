#include <stdint.h>
typedef struct MTPSession MTPSession;
typedef void (*MTPEntryCallback)(uint32_t, uint32_t, const char *, uint64_t, int, void *);
typedef int (*MTPProgressCallback)(uint64_t, uint64_t, const void *);
MTPSession *mtp_create(void);
void mtp_destroy(MTPSession *);
const char *mtp_error(MTPSession *);
int mtp_connect(MTPSession *);
int mtp_list(MTPSession *, uint32_t storage, uint32_t parent, MTPEntryCallback, void *);
int mtp_download(MTPSession *, uint32_t id, int fd, MTPProgressCallback, void *);
int mtp_upload(MTPSession *, uint32_t storage, uint32_t parent, const char *path, const char *name, MTPProgressCallback, void *);
int mtp_create_folder(MTPSession *, uint32_t storage, uint32_t parent, const char *name, uint32_t *folder_id);
int mtp_rename(MTPSession *, uint32_t id, const char *name);
