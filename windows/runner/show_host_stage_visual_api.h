#ifndef RUNNER_SHOW_HOST_STAGE_VISUAL_API_H_
#define RUNNER_SHOW_HOST_STAGE_VISUAL_API_H_

#include <stdbool.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define SHOW_HOST_STAGE_VISUAL_EXPORT_NAME "show_host_get_stage_visual_api"
#define SHOW_HOST_STAGE_VISUAL_PROTOCOL_REVISION "nt-keyed-latest-v1"

typedef void *ShowHostHandle;
typedef void *ShowHostStageVisualSource;

enum {
  SHOW_HOST_STAGE_VISUAL_ABI_VERSION = 1,
  SHOW_HOST_STAGE_VISUAL_SYNC_KEYED_MUTEX = 1,
  SHOW_HOST_STAGE_VISUAL_FRAME_RESOURCE_CHANGED = 1 << 0,
  SHOW_HOST_STAGE_VISUAL_CAP_NT_HANDLE = 1 << 0,
  SHOW_HOST_STAGE_VISUAL_CAP_KEYED_MUTEX = 1 << 1,
  SHOW_HOST_STAGE_VISUAL_CAP_LATEST_FRAME = 1 << 2,
  SHOW_HOST_STAGE_VISUAL_CAP_NONBLOCKING_PRODUCER = 1 << 3,
};

typedef enum ShowHostStageVisualResult {
  SHOW_HOST_STAGE_VISUAL_SUCCESS = 0,
  SHOW_HOST_STAGE_VISUAL_INVALID_ARGUMENT = 1,
  SHOW_HOST_STAGE_VISUAL_VERSION_MISMATCH = 2,
  SHOW_HOST_STAGE_VISUAL_UNAVAILABLE = 3,
} ShowHostStageVisualResult;

typedef struct ShowHostStageVisualFrame {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t flags;
  uint32_t sync_type;
  uintptr_t shared_nt_handle;
  uint32_t width;
  uint32_t height;
  uint32_t dxgi_format;
  uint32_t reserved0;
  uint64_t resource_generation;
  uint64_t content_generation;
  uint64_t frame_id;
  uint64_t consumer_acquire_key;
  uint64_t consumer_release_key;
  uint64_t reserved[4];
} ShowHostStageVisualFrame;

typedef void (*ShowHostStageVisualFrameAvailableCallback)(
    void *user_data, const ShowHostStageVisualFrame *frame);

typedef struct ShowHostStageVisualStats {
  uint32_t struct_size;
  uint32_t abi_version;
  int32_t last_hresult;
  uint32_t reserved0;
  uint64_t published_frames;
  uint64_t producer_busy_drops;
  uint64_t callback_count;
  uint64_t resource_recreations;
  uint64_t resource_generation;
  uint64_t content_generation;
  uint64_t frame_id;
  uint64_t reserved[4];
} ShowHostStageVisualStats;

typedef int32_t (*ShowHostStageVisualCreateSource)(
    ShowHostHandle host, ShowHostStageVisualSource *source);
typedef void (*ShowHostStageVisualDestroySource)(
    ShowHostStageVisualSource source);
typedef void (*ShowHostStageVisualSetActive)(ShowHostStageVisualSource source,
                                             bool active);
typedef void (*ShowHostStageVisualSetFrameCallback)(
    ShowHostStageVisualSource source,
    ShowHostStageVisualFrameAvailableCallback callback, void *user_data);
typedef int32_t (*ShowHostStageVisualGetStats)(ShowHostStageVisualSource source,
                                               ShowHostStageVisualStats *stats);

typedef struct ShowHostStageVisualApi {
  uint32_t struct_size;
  uint32_t abi_version;
  uint64_t capabilities;
  const char *protocol_revision;
  ShowHostStageVisualCreateSource create_source;
  ShowHostStageVisualDestroySource destroy_source;
  ShowHostStageVisualSetActive set_active;
  ShowHostStageVisualSetFrameCallback set_frame_callback;
  ShowHostStageVisualGetStats get_stats;
  uint64_t reserved[4];
} ShowHostStageVisualApi;

typedef int32_t (*ShowHostGetStageVisualApiProc)(uint32_t requested_abi_version,
                                                 ShowHostStageVisualApi *api);
typedef bool (*ShowHostSetStageD3dDeviceProc)(ShowHostHandle host,
                                              uintptr_t d3d11_device);

#if defined(__cplusplus)
} // extern "C"
#endif

#endif // RUNNER_SHOW_HOST_STAGE_VISUAL_API_H_
