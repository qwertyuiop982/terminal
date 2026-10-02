package com.terminal

import android.app.Activity
import android.view.ViewGroup

/** Release contains no listener, remote API, token, assets or service declaration. */
object DebugFeatures {
    fun attach(activity: Activity, root: ViewGroup) = Unit
}