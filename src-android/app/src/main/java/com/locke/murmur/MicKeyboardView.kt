package com.locke.murmur

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

class MicKeyboardView(context: Context, private val listener: Listener) : View(context) {

    interface Listener {
        fun onPressStart()
        fun onPressEnd()
    }

    enum class State { IDLE, RECORDING, PROCESSING }

    var state: State = State.IDLE
        set(value) { field = value; invalidate() }

    private val bgPaint = Paint().apply {
        color = Color.parseColor("#141416")
        style = Paint.Style.FILL
    }
    private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#888888")
        textAlign = Paint.Align.CENTER
        textSize = 13 * resources.displayMetrics.scaledDensity
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN   -> listener.onPressStart()
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> listener.onPressEnd()
        }
        return true
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val dp = resources.displayMetrics.density

        // Background
        canvas.drawRect(0f, 0f, w, h, bgPaint)

        val cx = w / 2f
        val cy = h / 2f
        val radius = 36 * dp

        // Button circle
        circlePaint.color = when (state) {
            State.IDLE       -> Color.parseColor("#3A3A3C")
            State.RECORDING  -> Color.parseColor("#FF3B30")
            State.PROCESSING -> Color.parseColor("#2C2C2E")
        }
        canvas.drawCircle(cx, cy, radius, circlePaint)

        // Mic icon
        val iconColor = when (state) {
            State.IDLE       -> Color.parseColor("#EBEBF5")
            State.RECORDING  -> Color.WHITE
            State.PROCESSING -> Color.parseColor("#636366")
        }
        val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = iconColor
            style = Paint.Style.FILL
        }
        val mw = 9 * dp
        val mh = 14 * dp
        val mt = cy - mh * 0.65f
        // Capsule body
        val bodyRect = RectF(cx - mw / 2, mt, cx + mw / 2, mt + mh)
        canvas.drawRoundRect(bodyRect, mw / 2, mw / 2, iconPaint)
        // Stand arc
        val standPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = iconColor
            style = Paint.Style.STROKE
            strokeWidth = 1.8f * dp
            strokeCap = Paint.Cap.ROUND
        }
        val standR = mw * 0.9f
        val standTop = mt + mh - mw / 2
        val arcRect = RectF(cx - standR, standTop - standR, cx + standR, standTop + standR)
        canvas.drawArc(arcRect, 0f, 180f, false, standPaint)
        // Stand pole
        canvas.drawLine(cx, standTop + standR, cx, standTop + standR + 4 * dp, standPaint)

        // Hint label (idle only)
        if (state == State.IDLE) {
            canvas.drawText("按住说话", cx, cy + radius + 18 * dp, labelPaint)
        }
    }
}
