#include "MTPBridge.h"
#include <libmtp.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
struct MTPSession { LIBMTP_mtpdevice_t *device; char error[1024]; };
static int fail(MTPSession *s, const char *message) {
    LIBMTP_error_t *e = s->device ? LIBMTP_Get_Errorstack(s->device) : NULL;
    snprintf(s->error, sizeof(s->error), "%s%s%s", message, e ? ": " : "", e && e->error_text ? e->error_text : "");
    if (s->device) LIBMTP_Clear_Errorstack(s->device);
    return -1;
}
MTPSession *mtp_create(void) { LIBMTP_Init(); return calloc(1, sizeof(MTPSession)); }
void mtp_destroy(MTPSession *s) { if (!s) return; if(s->device) LIBMTP_Release_Device(s->device); free(s); }
const char *mtp_error(MTPSession *s) { return s->error; }
int mtp_connect(MTPSession *s) {
    if(s->device) { LIBMTP_Release_Device(s->device); s->device = NULL; }
    LIBMTP_raw_device_t *devices = NULL; int count = 0;
    LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&devices, &count);
    if(result != LIBMTP_ERROR_NONE || count == 0) { free(devices); return fail(s, "No Android device found. Unlock your phone, select File transfer, and use a data-capable USB cable."); }
    if(count != 1) { free(devices); return fail(s, "Connect just one MTP device, then try again."); }
    s->device = LIBMTP_Open_Raw_Device_Uncached(&devices[0]); free(devices);
    if(!s->device) return fail(s, "Cannot open phone. Allow file access on the phone and quit other USB transfer apps.");
    return 0;
}
int mtp_list(MTPSession *s, uint32_t storage, uint32_t parent, MTPEntryCallback cb, void *ctx) {
    if(!s->device) return fail(s, "Connect your phone first.");
    LIBMTP_Clear_Errorstack(s->device);
    if(storage == 0) {
        if(LIBMTP_Get_Storage(s->device, 0) != 0) return fail(s, "Cannot read phone storage");
        for(LIBMTP_devicestorage_t *p = s->device->storage; p; p = p->next)
            cb(0xffffffff, p->id, p->StorageDescription ? p->StorageDescription : "Phone storage", p->FreeSpaceInBytes, 1, ctx);
        return 0;
    }
    LIBMTP_file_t *p = LIBMTP_Get_Files_And_Folders(s->device, storage, parent);
    while(p) {
        cb(p->item_id, p->storage_id, p->filename ? p->filename : "Unnamed", p->filesize, p->filetype == LIBMTP_FILETYPE_FOLDER, ctx);
        LIBMTP_file_t *next = p->next; p->next = NULL; LIBMTP_destroy_file_t(p); p = next;
    }
    if(LIBMTP_Get_Errorstack(s->device)) return fail(s, "Cannot read folder. Reconnect if the phone was unplugged");
    return 0;
}
int mtp_download(MTPSession *s, uint32_t id, int fd, MTPProgressCallback cb, void *ctx) {
    if(!s->device) return fail(s, "Connect your phone first.");
    LIBMTP_Clear_Errorstack(s->device);
    if(LIBMTP_Get_File_To_File_Descriptor(s->device, id, fd, cb, ctx)) return fail(s, "Download failed. Reconnect the phone and retry");
    return 0;
}
int mtp_upload(MTPSession *s, uint32_t storage, uint32_t parent, const char *path, const char *name, MTPProgressCallback cb, void *ctx) {
    if(!s->device) return fail(s, "Connect your phone first.");
    struct stat st;
    if(stat(path, &st) || !S_ISREG(st.st_mode)) return fail(s, "Select a regular file to upload.");
    LIBMTP_Clear_Errorstack(s->device);
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    if(!file) return fail(s, "Not enough memory.");
    file->filename = strdup(name); file->filesize = st.st_size;
    file->storage_id = storage; file->parent_id = parent == 0xffffffff ? 0 : parent;
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    int result = LIBMTP_Send_File_From_File(s->device, path, file, cb, ctx);
    LIBMTP_destroy_file_t(file);
    if(result) return fail(s, "Upload failed. The phone may contain an incomplete file; inspect it before retrying");
    return 0;
}
int mtp_create_folder(MTPSession *s, uint32_t storage, uint32_t parent, const char *name, uint32_t *folder_id) {
    if(!s->device) return fail(s, "Connect your phone first.");
    if(!name || !folder_id) return fail(s, "Invalid folder request.");
    LIBMTP_Clear_Errorstack(s->device);
    char *copy = strdup(name);
    if(!copy) return fail(s, "Not enough memory.");
    uint32_t id = LIBMTP_Create_Folder(s->device, copy, parent == 0xffffffff ? 0 : parent, storage);
    free(copy);
    if(id == 0) return fail(s, "Could not create folder on the phone");
    *folder_id = id;
    return 0;
}
int mtp_rename(MTPSession *s, uint32_t id, const char *name) {
    if(!s->device) return fail(s, "Connect your phone first.");
    if(!name) return fail(s, "Invalid rename request.");
    LIBMTP_Clear_Errorstack(s->device);
    char *copy = strdup(name);
    if(!copy) return fail(s, "Not enough memory.");
    int result = LIBMTP_Set_Object_Filename(s->device, id, copy);
    free(copy);
    if(result != 0) return fail(s, "Could not rename item on the phone");
    return 0;
}
int mtp_delete(MTPSession *s, uint32_t id) {
    if(!s->device) return fail(s, "Connect your phone first.");
    LIBMTP_Clear_Errorstack(s->device);
    if(LIBMTP_Delete_Object(s->device, id) != 0) return fail(s, "Could not delete item from the phone");
    return 0;
}
