package com.locke.murmur

import android.inputmethodservice.InputMethodService
import android.view.View

class MurmurIME : InputMethodService() {
    override fun onCreateInputView(): View = View(this)
}
