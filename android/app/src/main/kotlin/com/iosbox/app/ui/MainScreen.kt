package com.iosbox.app.ui

import android.net.Uri
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.TextButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.iosbox.app.AppContainer
import com.iosbox.app.R
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ChatDraft
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.core.system.IncomingEntryRequest
import com.iosbox.app.core.system.InitialConversationDraft
import com.iosbox.app.ui.assistants.AssistantListScreen
import com.iosbox.app.ui.chat.ChatDetailScreen
import com.iosbox.app.ui.chat.ConversationListScreen
import com.iosbox.app.ui.chat.GroupSetupSheet
import com.iosbox.app.ui.providers.ProviderDetailScreen
import com.iosbox.app.ui.providers.ProviderListScreen
import com.iosbox.app.ui.settings.PersonalMemoryScreen
import com.iosbox.app.ui.study.FlashcardReviewScreen
import com.iosbox.app.ui.system.ExternalShareDialog
import com.iosbox.app.ui.usage.UsageScreen
import kotlinx.coroutines.launch

private object Routes {
    const val CHATS = "chats"
    const val ASSISTANTS = "assistants"
    const val PROVIDERS = "providers"
    const val USAGE = "usage"
    const val CHAT_DETAIL = "chat/{conversationId}"
    const val PROVIDER_DETAIL = "provider/{providerId}"
    const val MEMORIES = "memories"
    const val FLASHCARDS = "flashcards"

    fun chatDetail(id: String) = "chat/${Uri.encode(id)}"
    fun providerDetail(id: String) = "provider/$id"
}

@Composable
fun MainScreen(container: AppContainer) {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination
    val scope = rememberCoroutineScope()
    var showCreateGroupSheet by remember { mutableStateOf(false) }
    var externalDraftArena by rememberSaveable { mutableStateOf<Boolean?>(null) }
    var externalDraftText by rememberSaveable { mutableStateOf("") }
    val providers by container.chatRepository.observeProviders().collectAsStateWithLifecycle(initialValue = emptyList())
    val personaProfiles by container.chatRepository.observePersonaProfiles().collectAsStateWithLifecycle(initialValue = emptyList())
    val incomingRequest by container.externalEntryRouter.pendingRequest.collectAsStateWithLifecycle()
    val prefs by container.preferences.state.collectAsStateWithLifecycle()

    val topLevelRoutes = if (prefs.simpleDailyMode) {
        setOf(Routes.CHATS, Routes.ASSISTANTS, Routes.PROVIDERS)
    } else {
        setOf(Routes.CHATS, Routes.ASSISTANTS, Routes.PROVIDERS, Routes.USAGE)
    }
    val showBottomBar = currentDestination?.route in topLevelRoutes

    val openNewChat: (PresetItem?) -> Unit = { preset ->
        scope.launch {
            val currentProviders = container.chatRepository.getProviders()
            val ready = ChatRepository.readyTargets(currentProviders)
            val defaultId = container.preferences.state.value.defaultTargetID
            val target = defaultId?.let { id -> ready.firstOrNull { it.id == id } } ?: ready.firstOrNull()
            val created = container.chatRepository.createConversation(preset = preset, primaryTarget = target)
            navController.navigate(Routes.chatDetail(created.id))
        }
    }

    val openNewArena: () -> Unit = {
        scope.launch {
            val currentProviders = container.chatRepository.getProviders()
            val ready = ChatRepository.readyTargets(currentProviders)
            val created = container.chatRepository.createConversation(
                isArenaMode = true,
                arenaTargets = ready.take(2)
            )
            navController.navigate(Routes.chatDetail(created.id))
        }
    }

    LaunchedEffect(incomingRequest) {
        when (val req = incomingRequest) {
            is IncomingEntryRequest.OpenConversation -> {
                val conversation = container.chatRepository.getConversation(req.conversationId)
                if (container.externalEntryRouter.consumeRequest(req) && conversation != null) {
                    runCatching {
                        navController.navigate(Routes.chatDetail(conversation.id)) { launchSingleTop = true }
                    }
                }
            }
            IncomingEntryRequest.NewChat, IncomingEntryRequest.NewArena -> {
                if (container.externalEntryRouter.consumeRequest(req) && externalDraftArena == null) {
                    externalDraftText = ""
                    externalDraftArena = req == IncomingEntryRequest.NewArena
                }
            }
            IncomingEntryRequest.OpenFlashcards -> {
                container.externalEntryRouter.clearPendingRequest()
                navController.navigate(Routes.FLASHCARDS) {
                    launchSingleTop = true
                }
            }
            is IncomingEntryRequest.SharedContent, null -> Unit
        }
    }

    Scaffold(
        bottomBar = {
            if (showBottomBar) {
                NavigationBar {
                    NavigationBarItem(
                        selected = currentDestination?.hierarchy?.any { it.route == Routes.CHATS } == true,
                        onClick = {
                            navController.navigate(Routes.CHATS) {
                                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = { Icon(Icons.AutoMirrored.Filled.Chat, contentDescription = null) },
                        label = { Text(stringResource(R.string.tab_chats)) }
                    )
                    NavigationBarItem(
                        selected = currentDestination?.hierarchy?.any { it.route == Routes.ASSISTANTS } == true,
                        onClick = {
                            navController.navigate(Routes.ASSISTANTS) {
                                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = { Icon(Icons.Filled.GridView, contentDescription = null) },
                        label = { Text(stringResource(R.string.tab_assistants)) }
                    )
                    NavigationBarItem(
                        selected = currentDestination?.hierarchy?.any { it.route == Routes.PROVIDERS } == true,
                        onClick = {
                            navController.navigate(Routes.PROVIDERS) {
                                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                        label = { Text(stringResource(R.string.tab_providers)) }
                    )
                    if (!prefs.simpleDailyMode) {
                        NavigationBarItem(
                            selected = currentDestination?.hierarchy?.any { it.route == Routes.USAGE } == true,
                            onClick = {
                                navController.navigate(Routes.USAGE) {
                                    popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Icon(Icons.Filled.BarChart, contentDescription = null) },
                            label = { Text(stringResource(R.string.tab_usage)) }
                        )
                    }
                }
            }
        }
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = Routes.CHATS,
            modifier = Modifier.padding(innerPadding)
        ) {
            composable(Routes.CHATS) {
                ConversationListScreen(
                    container = container,
                    onOpenConversation = { id -> navController.navigate(Routes.chatDetail(id)) },
                    onCreateConversation = { openNewChat(null) },
                    onCreateArenaConversation = openNewArena,
                    onCreateGroupConversation = { showCreateGroupSheet = true },
                    onGoToProviders = {
                        navController.navigate(Routes.PROVIDERS) {
                            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    onOpenFlashcards = { navController.navigate(Routes.FLASHCARDS) }
                )
            }
            composable(Routes.ASSISTANTS) {
                AssistantListScreen(
                    container = container,
                    onStartChatWithPreset = { preset -> openNewChat(preset) },
                    onStartPrivatePersonaChat = { member ->
                        scope.launch {
                            val conv = container.chatRepository.openOrCreatePrivatePersonaChat(member)
                            navController.navigate(Routes.chatDetail(conv.id))
                        }
                    },
                    onOpenConversation = { id -> navController.navigate(Routes.chatDetail(id)) }
                )
            }
            composable(Routes.PROVIDERS) {
                ProviderListScreen(
                    container = container,
                    onOpenProvider = { id -> navController.navigate(Routes.providerDetail(id)) },
                    onOpenMemories = { navController.navigate(Routes.MEMORIES) },
                    onOpenFlashcards = { navController.navigate(Routes.FLASHCARDS) },
                    onOpenUsage = { navController.navigate(Routes.USAGE) }
                )
            }
            composable(Routes.USAGE) {
                UsageScreen(
                    container = container,
                    onBack = if (prefs.simpleDailyMode) {
                        { navController.popBackStack() }
                    } else null
                )
            }
            composable(Routes.MEMORIES) {
                PersonalMemoryScreen(
                    container = container,
                    onBack = { navController.popBackStack() }
                )
            }
            composable(Routes.FLASHCARDS) {
                FlashcardReviewScreen(
                    container = container,
                    onBack = { navController.popBackStack() }
                )
            }
            composable(
                route = Routes.CHAT_DETAIL,
                arguments = listOf(navArgument("conversationId") { type = NavType.StringType })
            ) { entry ->
                val convId = entry.arguments?.getString("conversationId") ?: return@composable
                ChatDetailScreen(
                    conversationId = convId,
                    container = container,
                    onBack = { navController.popBackStack() },
                    onGoToProviders = {
                        navController.popBackStack()
                        navController.navigate(Routes.PROVIDERS)
                    },
                    onOpenMemories = { navController.navigate(Routes.MEMORIES) },
                    onOpenConversation = { id -> navController.navigate(Routes.chatDetail(id)) },
                    onOpenFlashcards = { navController.navigate(Routes.FLASHCARDS) }
                )
            }
            composable(
                route = Routes.PROVIDER_DETAIL,
                arguments = listOf(navArgument("providerId") { type = NavType.StringType })
            ) { entry ->
                val providerId = entry.arguments?.getString("providerId") ?: return@composable
                ProviderDetailScreen(
                    providerId = providerId,
                    container = container,
                    onBack = { navController.popBackStack() }
                )
            }
        }
    }

    externalDraftArena?.let { arena ->
        AlertDialog(
            onDismissRequest = { externalDraftArena = null },
            title = { Text(if (arena) L10n.text("新建竞技场", "New Arena") else L10n.text("新建对话", "New Chat")) },
            text = {
                OutlinedTextField(
                    value = externalDraftText,
                    onValueChange = { externalDraftText = it },
                    label = { Text(L10n.text("消息草稿", "Message draft")) },
                    minLines = 3
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val draft = externalDraftText.trim()
                    externalDraftArena = null
                    scope.launch {
                        val ready = ChatRepository.readyTargets(container.chatRepository.getProviders())
                        val target = ready.firstOrNull { it.id == container.preferences.state.value.defaultTargetID }
                            ?: ready.firstOrNull()
                        val created = container.chatRepository.createConversation(
                            primaryTarget = target.takeUnless { arena },
                            isArenaMode = arena,
                            arenaTargets = if (arena) ready.take(2) else emptyList(),
                            initialDraft = draft.takeIf { it.isNotEmpty() }?.let { ChatDraft(text = it) }
                        )
                        if (draft.isNotEmpty()) {
                            container.externalEntryRouter.stageInitialDraft(created.id, InitialConversationDraft(draft, userAuthored = true))
                        }
                        navController.navigate(Routes.chatDetail(created.id))
                    }
                }) { Text(L10n.text("继续编辑", "Continue editing")) }
            },
            dismissButton = {
                TextButton(onClick = { externalDraftArena = null }) { Text(L10n.text("取消", "Cancel")) }
            }
        )
    }

    if (showCreateGroupSheet) {
        GroupSetupSheet(
            existing = null,
            providers = providers,
            personaProfiles = personaProfiles,
            onSave = { title, emoji, systemPrompt, members, speakingMode, speechStyle, maxRelayTurns, splitShortBubbles ->
                scope.launch {
                    val created = container.chatRepository.createGroupConversation(
                        title = title,
                        emoji = emoji,
                        systemPrompt = systemPrompt,
                        members = members,
                        speakingMode = speakingMode,
                        speechStyle = speechStyle,
                        maxRelayTurns = maxRelayTurns,
                        splitShortBubbles = splitShortBubbles
                    )
                    navController.navigate(Routes.chatDetail(created.id))
                }
            },
            onDismiss = { showCreateGroupSheet = false }
        )
    }

    val shareReq = incomingRequest as? IncomingEntryRequest.SharedContent
    if (shareReq != null) {
        key(shareReq) {
            ExternalShareDialog(
                payload = shareReq.payload,
                container = container,
                isCurrent = { container.externalEntryRouter.pendingRequest.value == shareReq },
                onDismiss = { container.externalEntryRouter.consumeRequest(shareReq) },
                onOpenConversation = { id ->
                    if (container.externalEntryRouter.consumeRequest(shareReq)) {
                        navController.navigate(Routes.chatDetail(id)) { launchSingleTop = true }
                    }
                }
            )
        }
    }
}
