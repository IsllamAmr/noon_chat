import java.io.File

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val defaultBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(defaultBuildDir)
val tempBuildRoot = File(System.getProperty("java.io.tmpdir"), "noon_chat_build")

subprojects {
    if (project.name == "app") {
        project.layout.buildDirectory.value(defaultBuildDir.dir(project.name))
    } else {
        val newSubprojectBuildDir = File(tempBuildRoot, project.name)
        project.layout.buildDirectory.set(newSubprojectBuildDir)
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

