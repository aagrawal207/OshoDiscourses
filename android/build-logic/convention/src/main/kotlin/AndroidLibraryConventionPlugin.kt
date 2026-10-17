import com.agraabhi.oshodiscourses.buildlogic.configureAndroidLibrary
import org.gradle.api.Plugin
import org.gradle.api.Project

/** An Android library without UI: playback, downloads, DSP, sync, billing, data. */
class AndroidLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.library")
        pluginManager.apply("org.jetbrains.kotlin.plugin.serialization")
        configureAndroidLibrary()
    }
}
