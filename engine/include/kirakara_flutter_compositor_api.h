// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_WINDOWS_KIRAKARA_FLUTTER_COMPOSITOR_API_H_
#define FLUTTER_SHELL_PLATFORM_WINDOWS_KIRAKARA_FLUTTER_COMPOSITOR_API_H_

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define KIRAKARA_FLUTTER_COMPOSITOR_EXPORT_NAME \
  "FlutterDesktopKirakaraCompositorGetApi"
#define KIRAKARA_FLUTTER_COMPOSITOR_ABI_VERSION 2u
#define KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_VERSION 5u
#define KIRAKARA_FLUTTER_COMPOSITOR_PATCHSET_REVISION \
  "windows-dcomp-stage-visual"
#define KIRAKARA_FLUTTER_COMPOSITOR_ENGINE_REVISION \
  "a10d8ac38de835021c8d2f920dbf50a920ccc030"

typedef enum KirakaraFlutterCompositorResult {
  kKirakaraFlutterCompositorSuccess = 0,
  kKirakaraFlutterCompositorInvalidArgument = 1,
  kKirakaraFlutterCompositorVersionMismatch = 2,
  kKirakaraFlutterCompositorBusy = 3,
  kKirakaraFlutterCompositorUnavailable = 4,
  kKirakaraFlutterCompositorViewNotConfigured = 5,
  kKirakaraFlutterCompositorFrameDropped = 6,
  kKirakaraFlutterCompositorOperationFailed = 7,
} KirakaraFlutterCompositorResult;

typedef enum KirakaraFlutterCompositorConfigFlag {
  kKirakaraFlutterCompositorSyntheticStage = 1u << 0,
  kKirakaraFlutterCompositorRequireComposition = 1u << 1,
  kKirakaraFlutterCompositorExternalStage = 1u << 2,
} KirakaraFlutterCompositorConfigFlag;

typedef enum KirakaraFlutterCompositorCapability {
  kKirakaraFlutterCompositorDirectComposition = 1ull << 0,
  kKirakaraFlutterCompositorPremultipliedAlpha = 1ull << 1,
  kKirakaraFlutterCompositorSyntheticStageProducer = 1ull << 2,
  kKirakaraFlutterCompositorIndependentStageProducer = 1ull << 3,
  kKirakaraFlutterCompositorCompositorClockPacing = 1ull << 4,
  kKirakaraFlutterCompositorInPlaceResize = 1ull << 5,
  kKirakaraFlutterCompositorExternalStageConsumer = 1ull << 6,
  kKirakaraFlutterCompositorNtHandle = 1ull << 7,
  kKirakaraFlutterCompositorKeyedMutex = 1ull << 8,
  kKirakaraFlutterCompositorLatestFrame = 1ull << 9,
  kKirakaraFlutterCompositorEventDrivenConsumer = 1ull << 10,
  kKirakaraFlutterCompositorStageFitAndClip = 1ull << 11,
} KirakaraFlutterCompositorCapability;

typedef enum KirakaraFlutterCompositorStageFrameFlag {
  kKirakaraFlutterCompositorStageResourceChanged = 1u << 0,
} KirakaraFlutterCompositorStageFrameFlag;

typedef enum KirakaraFlutterCompositorStageSyncType {
  kKirakaraFlutterCompositorStageSyncKeyedMutex = 1,
} KirakaraFlutterCompositorStageSyncType;

typedef enum KirakaraFlutterCompositorStageFit {
  kKirakaraFlutterCompositorStageFitContain = 0,
  kKirakaraFlutterCompositorStageFitCover = 1,
  kKirakaraFlutterCompositorStageFitFill = 2,
} KirakaraFlutterCompositorStageFit;

typedef struct KirakaraFlutterCompositorConfig {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t patchset_version;
  uint32_t flags;
  uintptr_t top_level_window;
  uint64_t reserved[4];
} KirakaraFlutterCompositorConfig;

// The shared_nt_handle value is borrowed for this call. The Engine duplicates
// it before returning whenever a new resource_generation is accepted.
typedef struct KirakaraFlutterCompositorStageFrame {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t patchset_version;
  uint32_t flags;
  uintptr_t shared_nt_handle;
  uint32_t width;
  uint32_t height;
  uint32_t dxgi_format;
  uint32_t sync_type;
  uint64_t resource_generation;
  uint64_t content_generation;
  uint64_t frame_id;
  uint64_t consumer_acquire_key;
  uint64_t consumer_release_key;
  uint64_t reserved[4];
} KirakaraFlutterCompositorStageFrame;

// Coordinates are physical client pixels in the top-level HWND. The Engine
// applies fit and clip only when this value changes; Stage frames never call
// DirectComposition from their producer callback.
typedef struct KirakaraFlutterCompositorStageGeometry {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t patchset_version;
  uint32_t visible;
  float x;
  float y;
  float width;
  float height;
  uint32_t fit;
  uint32_t reserved0;
  uint64_t reserved[4];
} KirakaraFlutterCompositorStageGeometry;

typedef struct KirakaraFlutterCompositorDiagnostics {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t patchset_version;
  uint32_t active;
  uint64_t capabilities;
  uintptr_t top_level_window;
  uint32_t width;
  uint32_t height;
  int32_t initialization_hresult;
  int32_t last_stage_present_hresult;
  int32_t last_stage_pacing_status;
  int32_t last_resize_hresult;
  uint64_t flutter_present_count;
  uint64_t stage_present_count;
  uint64_t stage_wait_wake_count;
  uint64_t stage_device_removed_count;
  uint64_t stage_occluded_count;
  uint64_t surface_resize_count;
  uint64_t composition_tree_commit_count;
  int32_t last_stage_resource_hresult;
  uint32_t reserved0;
  uint64_t stage_frame_submit_count;
  uint64_t stage_frame_coalesced_count;
  uint64_t stage_frame_stale_count;
  uint64_t stage_handle_duplicate_failure_count;
  uint64_t stage_resource_open_failure_count;
  uint64_t stage_acquire_busy_count;
  uint64_t stage_detach_count;
  uint64_t stage_geometry_update_count;
  uint64_t stage_resource_generation;
  uint64_t stage_content_generation;
  uint64_t stage_frame_id;
  uint64_t reserved[4];
} KirakaraFlutterCompositorDiagnostics;

typedef int32_t (*KirakaraFlutterCompositorPrepareNextView)(
    const KirakaraFlutterCompositorConfig* config);
typedef int32_t (*KirakaraFlutterCompositorCancelPreparedView)(void);
typedef int32_t (*KirakaraFlutterCompositorGetViewDiagnostics)(
    uintptr_t flutter_view,
    KirakaraFlutterCompositorDiagnostics* diagnostics);
typedef int32_t (*KirakaraFlutterCompositorSubmitStageFrame)(
    uintptr_t flutter_view,
    const KirakaraFlutterCompositorStageFrame* frame);
typedef int32_t (*KirakaraFlutterCompositorSetStageGeometry)(
    uintptr_t flutter_view,
    const KirakaraFlutterCompositorStageGeometry* geometry);
typedef int32_t (*KirakaraFlutterCompositorDetachStage)(uintptr_t flutter_view);

typedef struct KirakaraFlutterCompositorApi {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t patchset_version;
  uint32_t reserved0;
  const char* patchset_revision;
  const char* engine_revision;
  KirakaraFlutterCompositorPrepareNextView prepare_next_view;
  KirakaraFlutterCompositorCancelPreparedView cancel_prepared_view;
  KirakaraFlutterCompositorGetViewDiagnostics get_view_diagnostics;
  KirakaraFlutterCompositorSubmitStageFrame submit_stage_frame;
  KirakaraFlutterCompositorSetStageGeometry set_stage_geometry;
  KirakaraFlutterCompositorDetachStage detach_stage;
  uint64_t reserved[1];
} KirakaraFlutterCompositorApi;

typedef int32_t (*FlutterDesktopKirakaraCompositorGetApiProc)(
    uint32_t requested_abi_version,
    KirakaraFlutterCompositorApi* api);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_SHELL_PLATFORM_WINDOWS_KIRAKARA_FLUTTER_COMPOSITOR_API_H_
