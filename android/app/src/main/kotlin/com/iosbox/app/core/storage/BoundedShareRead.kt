package com.iosbox.app.core.storage

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal object BoundedShareRead {
    private fun executor(threads: Int, capacity: Int, name: String) = ThreadPoolExecutor(
        threads, threads, 30, TimeUnit.SECONDS, ArrayBlockingQueue(capacity),
        { task -> Thread(task, name).apply { isDaemon = true } }
    ).apply { allowCoreThreadTimeOut(true) }

    private val workers = executor(2, 2, "fugue-share-read")
    private val cancellation = executor(2, 4, "fugue-share-cancel")

    suspend fun <T : Any> run(timeoutMillis: Long, close: () -> Unit, read: (() -> Unit) -> T): T =
        withTimeoutOrNull(timeoutMillis) {
            suspendCancellableCoroutine { result ->
                val check = { if (!result.isActive) throw CancellationException() }
                val task = FutureTask<Unit> {
                    try {
                        check()
                        val value = read(check)
                        if (result.isActive) result.resume(value)
                    } catch (error: Exception) {
                        if (result.isActive) result.resumeWithException(error)
                    }
                }
                result.invokeOnCancellation {
                    task.cancel(true)
                    workers.remove(task)
                    try { cancellation.execute { runCatching(close) } }
                    catch (_: RejectedExecutionException) { /* Worker count remains bounded. */ }
                }
                try {
                    if (result.isActive) workers.execute(task)
                    if (!result.isActive) workers.remove(task)
                } catch (_: RejectedExecutionException) {
                    if (result.isActive) result.resumeWithException(AttachmentException.ShareReadUnavailable())
                }
            }
        } ?: throw AttachmentException.ShareReadUnavailable()
}
