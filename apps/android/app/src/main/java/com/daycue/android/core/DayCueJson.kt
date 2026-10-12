package com.daycue.android.core

import kotlinx.serialization.json.Json

/**
 * 全工程共用的 JSON 配置。
 *
 * 三条设置都有明确理由：
 * - ignoreUnknownKeys：契约对象标了 additionalProperties: false，但客户端必须能容忍后端加字段，
 *   否则后端一次灰度发布就会让老客户端解析失败；
 * - encodeDefaults：请求体要带齐 schema_version 这类默认值，不能因为「值等于默认值」就被省略；
 * - explicitNulls = false：与 Swift JSONEncoder 的行为对齐（可选字段为 nil 时直接不出现），
 *   避免双端请求体出现无意义的差异。
 */
val DayCueJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
    isLenient = false
}
