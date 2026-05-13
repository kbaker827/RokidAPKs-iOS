package com.rokidapks.glasses.tcp

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val TAG = "IosDiscovery"

/**
 * Discovers the iOS RokidAPKsPhone app via Bonjour/NSD and opens a TCP control connection.
 *
 * The iOS phone advertises "_rokidapks._tcp" on the local network. This class performs
 * NSD discovery and resolves the first matching service, then connects to it over TCP.
 * The resulting socket is used by [TcpControlChannel] for the offer/result handshake.
 */
class IosDiscoveryClient(private val context: Context) {

    companion object {
        const val SERVICE_TYPE = "_rokidapks._tcp."
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    /**
     * Discovers the iOS phone on the local network and returns a connected TCP [Socket].
     * Suspends until a service is found and resolved, or throws [IOException] on failure.
     *
     * @param timeoutMs How long to wait before giving up (default 30 s).
     */
    suspend fun connect(timeoutMs: Long = 30_000L): Socket {
        val serviceInfo = discoverAndResolve(timeoutMs)
        val host = serviceInfo.host ?: throw IOException("Resolved service has no host address.")
        val port = serviceInfo.port
        Log.d(TAG, "Connecting to iOS phone at ${host.hostAddress}:$port")

        return try {
            Socket().apply {
                tcpNoDelay = true
                connect(InetSocketAddress(host, port), 10_000)
            }
        } catch (e: Exception) {
            throw IOException("TCP connect to iOS phone failed: ${e.message}", e)
        }
    }

    // ── NSD discovery + resolve ──────────────────────────────────────────────

    private suspend fun discoverAndResolve(timeoutMs: Long): NsdServiceInfo =
        suspendCancellableCoroutine { cont ->
            var discoveryListener: NsdManager.DiscoveryListener? = null

            val resolveListener = object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, error: Int) {
                    Log.w(TAG, "Resolve failed for ${info.serviceName}: error $error")
                    if (cont.isActive) {
                        cont.resumeWithException(IOException("NSD resolve failed (error $error)."))
                    }
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    Log.d(TAG, "Resolved: ${info.serviceName} → ${info.host}:${info.port}")
                    discoveryListener?.let { runCatching { nsdManager.stopServiceDiscovery(it) } }
                    if (cont.isActive) cont.resume(info)
                }
            }

            discoveryListener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {
                    Log.d(TAG, "NSD discovery started for $type")
                }

                override fun onServiceFound(info: NsdServiceInfo) {
                    Log.d(TAG, "Found service: ${info.serviceName}")
                    // Resolve the first service we find
                    runCatching { nsdManager.resolveService(info, resolveListener) }
                        .onFailure { e ->
                            if (cont.isActive) {
                                cont.resumeWithException(
                                    IOException("NSD resolveService call failed: ${e.message}", e)
                                )
                            }
                        }
                }

                override fun onServiceLost(info: NsdServiceInfo) {
                    Log.d(TAG, "Service lost: ${info.serviceName}")
                }

                override fun onDiscoveryStopped(type: String) {
                    Log.d(TAG, "NSD discovery stopped")
                }

                override fun onStartDiscoveryFailed(type: String, error: Int) {
                    if (cont.isActive) {
                        cont.resumeWithException(IOException("NSD discovery start failed (error $error)."))
                    }
                }

                override fun onStopDiscoveryFailed(type: String, error: Int) {
                    Log.w(TAG, "NSD stop discovery failed: $error")
                }
            }

            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)

            cont.invokeOnCancellation {
                runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
            }
        }
}
