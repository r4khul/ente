import "package:photo_manager/photo_manager.dart";
import "package:shared_preferences/shared_preferences.dart";

class PermissionService {
  static const kHasGrantedPermissionsKey = "has_granted_permissions";
  static const kPermissionStateKey = "permission_state";
  static const _kRequestedOfflinePhotoPermission =
      "requested_offline_photo_permission";
  static const _kPendingOfflineSettingsGrant = "pending_offline_settings_grant";
  static const _photoLibraryAddRequestOption = PermissionRequestOption(
    iosAccessLevel: IosAccessLevel.addOnly,
  );
  final SharedPreferences _prefs;
  int _pendingPhotoPermissionRequests = 0;
  PermissionService(this._prefs);

  bool get isPhotoPermissionFlowPending =>
      _pendingPhotoPermissionRequests > 0 ||
      (_prefs.getBool(_kPendingOfflineSettingsGrant) ?? false);

  Future<PermissionState> requestPhotoMangerPermissions() async {
    _pendingPhotoPermissionRequests++;
    try {
      return await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.common,
            mediaLocation: true,
          ),
        ),
      );
    } finally {
      _pendingPhotoPermissionRequests--;
    }
  }

  bool get hasRequestedOfflinePhotoPermission =>
      _prefs.getBool(_kRequestedOfflinePhotoPermission) ?? false;

  Future<PermissionState> requestOfflinePhotoPermissions() async {
    final state = await requestPhotoMangerPermissions();
    await _prefs.setBool(_kRequestedOfflinePhotoPermission, true);
    return state;
  }

  Future<void> setOfflineSettingsGrantPending(bool value) async {
    if (value) {
      await _prefs.setBool(_kPendingOfflineSettingsGrant, true);
    } else {
      await _prefs.remove(_kPendingOfflineSettingsGrant);
    }
  }

  Future<PermissionState?> getPendingOfflineSettingsGrant() async {
    if (!(_prefs.getBool(_kPendingOfflineSettingsGrant) ?? false)) return null;
    final state = await getPermissionState();
    if (state.hasAccess) return state;
    await setOfflineSettingsGrantPending(false);
    return null;
  }

  Future<PermissionState> requestPhotoLibraryAddPermission() async {
    final state = await PhotoManager.getPermissionState(
      requestOption: _photoLibraryAddRequestOption,
    );
    return state == PermissionState.notDetermined
        ? PhotoManager.requestPermissionExtend(
            requestOption: _photoLibraryAddRequestOption,
          )
        : state;
  }

  bool hasGrantedPermissions() {
    return _prefs.getBool(kHasGrantedPermissionsKey) ?? false;
  }

  bool hasGrantedLimitedPermissions() {
    return _prefs.getString(kPermissionStateKey) ==
        PermissionState.limited.toString();
  }

  bool hasGrantedFullPermission() {
    return (_prefs.getString(kPermissionStateKey) ?? '') ==
        PermissionState.authorized.toString();
  }

  Future<void> onUpdatePermission(PermissionState state) async {
    await _prefs.setBool(kHasGrantedPermissionsKey, state.hasAccess);
    await _prefs.setString(kPermissionStateKey, state.toString());
  }

  Future<PermissionState> getPermissionState() {
    return PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.common,
          mediaLocation: true,
        ),
      ),
    );
  }
}
