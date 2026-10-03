package dev.qiyu.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Omni 双工通话的 microphone 前台服务（T05，spec:23）。
 *
 * 职责只有一个：在用户主动开始通话的可见界面里被 [OmniCallBridge] 拉起，
 * 挂一条系统要求的 microphone 前台提示，让锁屏／切 App 期间系统不冻结
 * 进程——采集、播放与会话状态都不在这里，全部归同进程的 OmniCallBridge
 * 与 Dart 侧通话控制器（页面进后台不新开连接，T05:13）。
 *
 * 生命周期纪律：
 * - START_NOT_STICKY：系统回收后**不**重建——「用户从系统入口停止后不得
 *   自行复活通话」（T05:14），重启出新的空服务只会骗出一条假通话提示。
 * - 系统或用户从系统入口停止本服务时 [onDestroy] 触发；是否「预期内」
 *   由 [OmniCallBridge] 通过挂/摘 [stoppedListener] 判定（它自己发起的
 *   stopService 会先摘监听），预期外即如实上报 Dart 结束通话。
 */
internal class OmniCallForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundWithMicType()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stoppedListener?.invoke()
        super.onDestroy()
    }

    private fun startForegroundWithMicType() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            // microphone 类型自 API 29 起存在；30+ 要求清单声明对应类型，
            // 34+ 另要求 FOREGROUND_SERVICE_MICROPHONE 权限与 while-in-use
            // 授权——均已在清单与 OmniCallBridge 的授权前置里覆盖。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val title = getString(R.string.omni_call_notification_title)
        val text = getString(R.string.omni_call_notification_text)
        return if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.omni_call_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .build()
        }
    }

    companion object {
        private const val CHANNEL_ID = "qiyu_omni_call"
        private const val NOTIFICATION_ID = 7063

        /** 预期外的服务停止回调（OmniCallBridge 挂/摘，见类注释）。 */
        @Volatile
        internal var stoppedListener: (() -> Unit)? = null

        /** 供 OmniCallBridge 构造启动意图（同一进程内显式意图）。 */
        internal fun intent(context: Context): Intent =
            Intent(context, OmniCallForegroundService::class.java)
    }
}
