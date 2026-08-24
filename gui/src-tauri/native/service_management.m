#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

static NSString *const EDPDaemonPlist = @"com.edp.usbvault.daemon.plist";

static SMAppService *edp_service(void) {
  return [SMAppService daemonServiceWithPlistName:EDPDaemonPlist];
}

static void edp_copy_error(NSError *error, char *buffer, size_t length) {
  if (buffer == NULL || length == 0) {
    return;
  }
  NSString *message = error.localizedFailureReason ?: error.localizedDescription ?: @"未知系统错误";
  const char *utf8 = message.UTF8String ?: "未知系统错误";
  strlcpy(buffer, utf8, length);
}

// Stable values consumed by Rust; do not expose Apple's enum raw values.
// 0 not registered, 1 enabled, 2 requires approval, 3 not found.
int edp_sm_service_status(void) {
  if (@available(macOS 13.0, *)) {
    switch (edp_service().status) {
      case SMAppServiceStatusNotRegistered: return 0;
      case SMAppServiceStatusEnabled: return 1;
      case SMAppServiceStatusRequiresApproval: return 2;
      case SMAppServiceStatusNotFound: return 3;
    }
  }
  return 3;
}

bool edp_sm_service_register(char *buffer, size_t length) {
  if (@available(macOS 13.0, *)) {
    SMAppService *service = edp_service();
    if (service.status == SMAppServiceStatusEnabled ||
        service.status == SMAppServiceStatusRequiresApproval) {
      return true;
    }
    NSError *error = nil;
    if ([service registerAndReturnError:&error]) {
      return true;
    }
    edp_copy_error(error, buffer, length);
    return false;
  }
  if (buffer != NULL && length > 0) {
    strlcpy(buffer, "需要 macOS 13 或更高版本", length);
  }
  return false;
}

bool edp_sm_service_unregister(char *buffer, size_t length) {
  if (@available(macOS 13.0, *)) {
    SMAppService *service = edp_service();
    if (service.status == SMAppServiceStatusNotRegistered) {
      return true;
    }
    NSError *error = nil;
    if ([service unregisterAndReturnError:&error]) {
      return true;
    }
    edp_copy_error(error, buffer, length);
    return false;
  }
  if (buffer != NULL && length > 0) {
    strlcpy(buffer, "需要 macOS 13 或更高版本", length);
  }
  return false;
}

void edp_sm_open_login_items(void) {
  if (@available(macOS 13.0, *)) {
    [SMAppService openSystemSettingsLoginItems];
  }
}
