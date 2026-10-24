package com.jeethsuresh.spacetime

import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.util.Base64
import org.json.JSONObject
import java.security.MessageDigest

/** A Binder-only native entry point. Instantiating this provider does not start
 * an Activity, Flutter engine, sync, alarms, or a network request. */
class StoreNotifications : ContentProvider() {
    companion object {
        fun sessionFingerprint(c: Context): String? {
            val key = Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(GravitasLogin.ORIGIN.toByteArray()), Base64.NO_WRAP)
            val encrypted = c.getSharedPreferences("spacetime.sessions", Context.MODE_PRIVATE).getString(key, null) ?: return null
            return Base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(encrypted.toByteArray()), Base64.NO_WRAP)
        }
        fun account(c: Context, snapshot: JSONObject) = synchronized(StoreNotifications::class.java) {
            val username = if (snapshot.optString("server") == GravitasLogin.ORIGIN) snapshot.optJSONObject("user")?.optString("username") else null
            val prefs = c.getSharedPreferences("spacetime.push-account", Context.MODE_PRIVATE)
            val fingerprint = sessionFingerprint(c)
            if (prefs.getString("username", null) != username || prefs.getString("session", null) != fingerprint) prefs.edit().putString("username", username).putString("session", fingerprint).commit()
        }
        fun clear(c: Context) = synchronized(StoreNotifications::class.java) {
            c.getSystemService(NotificationManager::class.java).activeNotifications.filter { it.tag?.startsWith("push:") == true }.forEach { c.getSystemService(NotificationManager::class.java).cancel(it.tag, it.id) }
            c.getSharedPreferences("spacetime.push", Context.MODE_PRIVATE).edit().clear().commit()
            c.getSharedPreferences("spacetime.push-account", Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
    override fun onCreate() = true
    @Suppress("DEPRECATION")
    private fun trusted(c: Context, uid: Int): Boolean = try {
        val pm = c.packageManager
        val packages = pm.getPackagesForUid(uid)?.toList().orEmpty()
        val info = pm.getPackageInfo(BrokerProtocol.PACKAGE, if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
        val signers = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        packages == listOf(BrokerProtocol.PACKAGE) && signers?.size == 1 &&
            MessageDigest.getInstance("SHA-256").digest(signers[0].toByteArray()).joinToString("") { "%02x".format(it) } == BrokerProtocol.CERTIFICATE
    } catch (_: Exception) { false }
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val c = requireNotNull(context)
        if (method != "notify" || arg != null || !trusted(c, Binder.getCallingUid())) throw SecurityException("Untrusted notification provider")
        val raw = extras?.getString("payload") ?: return Bundle().apply { putBoolean("accepted", true) }
        return try { StoreNotificationDelivery.deliver(c, raw) }
        catch (_: org.json.JSONException) { Bundle().apply { putBoolean("accepted", true) } }
        catch (_: IllegalArgumentException) { Bundle().apply { putBoolean("accepted", true) } }
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = throw UnsupportedOperationException()
    override fun getType(uri: Uri): String? = throw UnsupportedOperationException()
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}

/** Called only after signature-verified IPC; independently testable without Flutter. */
internal object StoreNotificationDelivery {
    fun deliver(c: Context, raw: String): Bundle {
        require(raw.length <= 8192)
        val payload = JSONObject(raw)
        val kind = payload.getString("kind"); require(kind in listOf("event.invited", "event.updated"))
        val event = payload.getString("event_id"); require(event.matches(Regex("[a-f0-9]{48}")))
        val version = payload.getInt("version"); require(version > 0)
        val title = payload.getString("title"); require(title.length <= 2000)
        val username = payload.getString("username")
        val accepted = Bundle().apply { putBoolean("accepted", true) }
        // A signed-out, different-account or self-hosted client must not display
        // notifications for the store's Gravitas account. No bearer leaves here.
        synchronized(StoreNotifications::class.java) {
            if (c.getSharedPreferences("spacetime.push-account", Context.MODE_PRIVATE).getString("username", null) != username ||
                StoreNotifications.sessionFingerprint(c).let { it == null || it != c.getSharedPreferences("spacetime.push-account", Context.MODE_PRIVATE).getString("session", null) } ||
                c.getSharedPreferences("spacetime.preferences", Context.MODE_PRIVATE).getString("spacetime.gravitas.disconnected", null) == "1") return accepted
            if (!LocalReminders.allowed(c)) return accepted
            val prefs = c.getSharedPreferences("spacetime.push", Context.MODE_PRIVATE)
            val tag = "$username:$event"
            if (prefs.getInt(tag, 0) >= version) return accepted
            val manager = c.getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel("calendar-updates", "Invites & event updates", NotificationManager.IMPORTANCE_DEFAULT))
            val date = runCatching { java.time.Instant.parse(payload.getString("start")).atZone(java.time.ZoneId.systemDefault()).toLocalDate().toString() }.getOrElse { java.time.LocalDate.now().toString() }
            val uri = Uri.parse("spacetime://calendar").buildUpon().appendQueryParameter("view", "Daily")
                .appendQueryParameter("date", date).build()
            val open = PendingIntent.getActivity(c, 0, Intent(c, MainActivity::class.java).setData(uri).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, "calendar-updates") else Notification.Builder(c)
            val text = if (kind == "event.invited") "You're invited · $title" else "Event updated · $title"
            val notification = builder.setSmallIcon(R.drawable.ic_notification).setContentTitle(if (kind == "event.invited") "New invitation" else "Calendar update")
                .setContentText(text).setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_EVENT).setVisibility(Notification.VISIBILITY_PRIVATE).build()
            manager.notify("push:$tag", 1, notification)
            // Keep a bounded highest-version cache. Replays update the same OS
            // notification, and older versions cannot replace a newer alert.
            val editor = prefs.edit().putInt(tag, version)
            if (prefs.all.size >= 512) prefs.all.keys.take(128).filter { it != tag }.forEach { editor.remove(it) }
            check(editor.commit())
        }
        return accepted
    }
}

/** Local IPC only; no login, token refresh or network request in Spacetime. */
object StoreNotificationClient {
    @Suppress("DEPRECATION")
    fun prepare(c: Context) {
        try {
            val pm = c.packageManager
            val info = pm.getPackageInfo(BrokerProtocol.PACKAGE, if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
            val signers = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
            if (signers?.size != 1 || MessageDigest.getInstance("SHA-256").digest(signers[0].toByteArray()).joinToString("") { "%02x".format(it) } != BrokerProtocol.CERTIFICATE) return
            val authority = BrokerProtocol.PACKAGE + ".notifications"
            if (pm.resolveContentProvider(authority, 0)?.packageName != BrokerProtocol.PACKAGE) return
            c.contentResolver.call(Uri.parse("content://$authority"), "prepare", null, null)
        } catch (_: Exception) { /* Optional distributor; the calendar remains offline-capable. */ }
    }
}
