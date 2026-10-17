package com.agraabhi.oshodiscourses.denoise

import android.content.Context
import com.agraabhi.oshodiscourses.denoise.dsp.DeepFilterModelSource
import com.agraabhi.oshodiscourses.denoise.dsp.DspLog
import java.io.File
import java.io.IOException

/**
 * The bundled DeepFilterNet 3 model. The Rust bridge reads a file path, so the APK asset
 * is copied once into no-backup storage; [modelPath] blocks and runs on the loader thread.
 */
class AssetDeepFilterModel(context: Context) : DeepFilterModelSource {
    private val appContext = context.applicationContext

    @Synchronized
    override fun modelPath(): String? {
        val target = File(appContext.noBackupFilesDir, FILE_NAME)
        val stamp = File(appContext.noBackupFilesDir, "$FILE_NAME.stamp")
        return try {
            // Keyed to the install, so an app update with a new model replaces the copy.
            @Suppress("DEPRECATION")
            val installed = appContext.packageManager.getPackageInfo(appContext.packageName, 0).lastUpdateTime.toString()
            if (!target.isFile || !stamp.isFile || stamp.readText() != installed) {
                val partial = File(appContext.noBackupFilesDir, "$FILE_NAME.partial")
                appContext.assets.open(ASSET_NAME).use { input ->
                    partial.outputStream().use { output -> input.copyTo(output) }
                }
                if (!partial.renameTo(target)) throw IOException("Could not install the model")
                stamp.writeText(installed)
                DspLog.info("DeepFilterNet", "Installed model (${target.length()} bytes)")
            }
            target.absolutePath
        } catch (error: Exception) {
            DspLog.error("DeepFilterNet", "Model asset unavailable: ${error.message}")
            null
        }
    }

    companion object {
        /** Staged by the build without a .gz suffix, which AGP would otherwise decompress. */
        const val ASSET_NAME = "DeepFilterNet3_onnx.model"
        const val FILE_NAME = "DeepFilterNet3_onnx.tar.gz"
    }
}
