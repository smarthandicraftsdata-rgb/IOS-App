@file:Suppress("SpellCheckingInspection")

package com.example.shlamp

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity

/**
 * Compatibility redirect for older shortcuts and app versions.
 * Daily control and lamp setup now live in the single My Lamps flow.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val destination = if (CloudTokenVault(this).readSession() != null) {
            CloudHomeActivity::class.java
        } else {
            CloudAccountActivity::class.java
        }
        startActivity(
            Intent(this, destination)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        )
        finish()
    }

    companion object {
        const val EXTRA_OPEN_NEARBY_SETUP = "open_nearby_setup"
    }
}
