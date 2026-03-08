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

    private companion object {
        val COLOR_BG           = Color.parseColor("#141416")
        val COLOR_CIRCLE_IDLE  = Color.parseColor("#3A3A3C")
        val COLOR_CIRCLE_REC   = Color.parseColor("#FF3B30")
        val COLOR_CIRCLE_PROC  = Color.parseColor("#2C2C2E")
        val COLOR_ICON_IDLE    = Color.parseColor("#EBEBF5")
        val COLOR_ICON_PROC    = Color.parseColor("#636366")
        val COLOR_LABEL        = Color.parseColor("#888888")
    }

    var state: State = State.IDLE
        set(value) { field = value; invalidate() }

    private val dp = resources.displayMetrics.density

    private val bgPaint = Paint().apply {
        color = COLOR_BG
        style = Paint.Style.FILL
    }
    private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val standPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.8f * resources.displayMetrics.density
        strokeCap = Paint.Cap.ROUND
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = COLOR_LABEL
        textAlign = Paint.Align.CENTER
        textSize = 13 * resources.displayMetrics.scaledDensity
    }

    private val bodyRect = RectF()
    private val arcRect  = RectF()

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

        canvas.drawRect(0f, 0f, w, h, bgPaint)

        val cx = w / 2f
        val cy = h / 2f
        val radius = 36 * dp

        circlePaint.color = when (state) {
            State.IDLE       -> COLOR_CIRCLE_IDLE
            State.RECORDING  -> COLOR_CIRCLE_REC
            State.PROCESSING -> COLOR_CIRCLE_PROC
        }
        canvas.drawCircle(cx, cy, radius, circlePaint)

        val iconColor = when (state) {
            State.IDLE       -> COLOR_ICON_IDLE
            State.RECORDING  -> Color.WHITE
            State.PROCESSING -> COLOR_ICON_PROC
        }
        iconPaint.color  = iconColor
        standPaint.color = iconColor

        val mw = 9 * dp
        val mh = 14 * dp
        val mt = cy - mh * 0.65f
        bodyRect.set(cx - mw / 2, mt, cx + mw / 2, mt + mh)
        canvas.drawRoundRect(bodyRect, mw / 2, mw / 2, iconPaint)

        val standR   = mw * 0.9f
        val standTop = mt + mh - mw / 2
        arcRect.set(cx - standR, standTop - standR, cx + standR, standTop + standR)
        canvas.drawArc(arcRect, 0f, 180f, false, standPaint)
        canvas.drawLine(cx, standTop + standR, cx, standTop + standR + 4 * dp, standPaint)

        if (state == State.IDLE) {
            canvas.drawText("按住说话", cx, cy + radius + 18 * dp, labelPaint)
        }
    }
}
