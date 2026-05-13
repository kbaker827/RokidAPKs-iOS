package com.rokidapks.glasses

import android.content.Context

object PendingInstallStore {
    private const val PREFS_NAME = "rokid_apks_ios_companion"
    private const val KEY_PENDING_APK_PATH = "pending_apk_path"
    private const val KEY_PENDING_APK_SAVED_AT = "pending_apk_saved_at"

    fun savePendingApk(context: Context, path: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .putString(KEY_PENDING_APK_PATH, path)
            .putLong(KEY_PENDING_APK_SAVED_AT, System.currentTimeMillis())
            .apply()
    }

    fun getPendingApk(context: Context): String? =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_PENDING_APK_PATH, null)

    fun getPendingApkSavedAt(context: Context): Long =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getLong(KEY_PENDING_APK_SAVED_AT, 0L)

    fun clearPendingApk(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
            .remove(KEY_PENDING_APK_PATH)
            .remove(KEY_PENDING_APK_SAVED_AT)
            .apply()
    }
}
