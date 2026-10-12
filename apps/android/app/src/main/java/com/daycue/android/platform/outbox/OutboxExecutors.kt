package com.daycue.android.platform.outbox

import com.daycue.android.AppContainer
import com.daycue.android.platform.OutboxExecutionRegistry
import com.daycue.android.platform.OutboxOperationExecutor
import com.daycue.android.platform.PlatformDependencies

/**
 * outbox 真实执行路径的装配点。
 *
 * 谁在什么时机调用：
 * - [install]：DayCueApplication.onCreate 调用一次（报告里给出那一行）。不调用的话
 *   Worker 拿不到执行者，记录会如实留在 pending，不会伪造成功。
 * - [processor]：由后台作业 OutboxRetryWorker.doWork 在每轮开始时构造，
 *   状态机由它驱动（报告里给出 Worker 的替换内容）。
 */
object OutboxExecutors {

    /** 注册真实执行者。可重复调用，测试里可以替换成替身。 */
    fun install(container: AppContainer) {
        OutboxExecutionRegistry.install(executor(container))
    }

    /**
     * create_reminder / delete_reminder 都落到 App 内待办。
     * extract_capture 与 update_reminder 没有处理者，处理器会把它们一次性终止
     * （见 OutboxOperationKinds.declaredButUnavailable），不会留在队列里空转。
     */
    fun executor(container: AppContainer): OutboxOperationExecutor {
        val todos = TaskBackedInAppTodoStore(
            tasks = container.taskRepository,
            taskDao = container.database.taskDao(),
            timeSource = container.timeSource,
        )
        val reminderHandler = InAppTodoReminderHandler(todos)
        return AppOutboxExecutor(
            handlers = mapOf(
                OutboxOperationKinds.CREATE_REMINDER to reminderHandler,
                OutboxOperationKinds.DELETE_REMINDER to reminderHandler,
            ),
        )
    }

    /**
     * 后台作业用的处理器。
     *
     * 依赖从 PlatformDependencies 取而不是从容器取：Worker 只有 Context，
     * 而 PlatformDependencies 已经是「后台组件能拿到的最小依赖表」，worker 因此可测。
     */
    fun processor(
        dependencies: PlatformDependencies,
        executor: OutboxOperationExecutor,
    ): OutboxProcessor = OutboxProcessor(
        store = DaoOutboxOperationStore(dependencies.outboxDao),
        executor = executor,
        timeSource = dependencies.timeSource,
        policy = OutboxRetryPolicy.DEFAULT,
        cancellation = TaskStatusOutboxCancellationGate(dependencies.taskRepository),
    )
}
