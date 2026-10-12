package com.daycue.android.ui.place

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.daycue.android.platform.permission.PermissionCenter
import com.daycue.android.ui.common.DayCueScreen
import com.daycue.android.ui.common.KeyValueLine
import com.daycue.android.ui.common.MessageCard
import com.daycue.android.ui.common.SectionHeader
import com.daycue.android.ui.rememberContainer

/**
 * 新建 / 编辑地点。
 *
 * 这一页最硬的一条：**位置必须由用户给出**。
 * 「使用当前位置」读的是系统最近一次真实定位（读不到就明确报错），
 * 也可以手工输入经纬度；两种方式都没有时保存按钮按下只会得到一句拒绝。
 * 刻意不做「在地图上选点」：本项目不引入地图 SDK，没有地图就没有可点的坐标，
 * 与其放一个假的默认点，不如让用户清楚知道现在还没有位置。
 */
@Composable
fun PlaceEditScreen(
    placeId: String?,
    onBack: () -> Unit,
    onSaved: (String) -> Unit,
) {
    val container = rememberContainer()
    val viewModel: PlaceViewModel = viewModel(
        factory = remember(container) {
            PlaceViewModel.factory(
                repository = container.placeRepository,
                geoChanges = container.geoCoordinator,
                locationPicker = container.locationPicker,
                catalog = container.placeCatalog,
            )
        },
    )
    val state by viewModel.state.collectAsState()

    // 进入这一页就准备草稿；placeId 为空表示新建，草稿里不会带任何位置。
    LaunchedEffect(placeId) { viewModel.startPlaceDraft(placeId) }

    // 权限只能由 Activity 申请；申请结果回来后重试一次取点，用户看到的是「刚授权就能用」。
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        viewModel.useCurrentLocation()
    }

    val draft = state.draft
    DayCueScreen(
        title = if (placeId == null) "新建地点" else "编辑地点",
        onBack = {
            viewModel.closeDraft()
            onBack()
        },
    ) { padding ->
        if (draft == null) {
            Column(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
                Text("正在读取地点…", style = MaterialTheme.typography.bodyMedium)
            }
            return@DayCueScreen
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            state.error?.let { MessageCard(it, isError = true) }
            state.message?.let { MessageCard(it) }

            SectionHeader(title = "基本信息", subtitle = "名称与半径会直接出现在围栏注册里")
            OutlinedTextField(
                value = draft.name,
                onValueChange = viewModel::updateDraftField,
                label = { Text("地点名称") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = draft.radiusMeters,
                onValueChange = viewModel::updateDraftRadius,
                label = { Text("半径（米，必须大于 0）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            OutlinedTextField(
                value = draft.address,
                onValueChange = viewModel::updateDraftAddress,
                label = { Text("地址（可选）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )

            SectionHeader(
                title = "位置",
                subtitle = "围栏只能用你给出的坐标；没有位置就保存不了",
            )
            Text(draft.positionText, style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                Button(onClick = {
                    // 先申请权限再取点：没有权限时 lastFix 一定返回 null，
                    // 直接调用只会让用户看到「读不到位置」而不知道是因为没授权。
                    if (PermissionCenter.hasFineLocation(container.context) ||
                        PermissionCenter.hasCoarseLocation(container.context)
                    ) {
                        viewModel.useCurrentLocation()
                    } else {
                        permissionLauncher.launch(
                            arrayOf(
                                PermissionCenter.ACCESS_FINE_LOCATION,
                                "android.permission.ACCESS_COARSE_LOCATION",
                            ),
                        )
                    }
                }) { Text("使用当前位置") }
            }
            OutlinedTextField(
                value = draft.latitude?.let { formatCoordinate(it) } ?: "",
                onValueChange = viewModel::updateDraftLatitude,
                label = { Text("纬度（-90 ~ 90，可手工输入）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            OutlinedTextField(
                value = draft.longitude?.let { formatCoordinate(it) } ?: "",
                onValueChange = viewModel::updateDraftLongitude,
                label = { Text("经度（-180 ~ 180，可手工输入）") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            Text(
                text = "手工输入会覆盖上面取到的位置；清空输入框即视为「还没有位置」。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )

            SectionHeader(title = "坐标系")
            KeyValueLine("坐标系", draft.coordinateSystem.displayName)
            Text(
                text = "Android 的 LocationManager 返回的是 WGS84 原始坐标，因此新建地点固定记成 WGS84。" +
                    "这一列必须存下来：将来接入 GCJ-02（高德 / 腾讯）取点来源时，" +
                    "同一地点两种坐标能差几百米，混在一起会让围栏整体偏移。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Button(
                onClick = { viewModel.savePlace { savedId -> onSaved(savedId) } },
                modifier = Modifier.padding(top = 16.dp, bottom = 24.dp),
            ) { Text("保存地点") }

            if (!draft.hasPosition) {
                Text(
                    text = "还没有位置：可以点「使用当前位置」，或手工输入经纬度。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            OutlinedButton(onClick = { viewModel.closeDraft(); onBack() }, modifier = Modifier.padding(bottom = 24.dp)) {
                Text("取消")
            }
        }
    }
}
