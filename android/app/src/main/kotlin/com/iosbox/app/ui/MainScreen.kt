package com.iosbox.app.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
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
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.ui.assistants.AssistantListScreen
import com.iosbox.app.ui.chat.ChatDetailScreen
import com.iosbox.app.ui.chat.ConversationListScreen
import com.iosbox.app.ui.providers.ProviderDetailScreen
import com.iosbox.app.ui.providers.ProviderListScreen
import com.iosbox.app.ui.usage.UsageScreen
import kotlinx.coroutines.launch

private object Routes {
    const val CHATS = "chats"
    const val ASSISTANTS = "assistants"
    const val PROVIDERS = "providers"
    const val USAGE = "usage"
    const val CHAT_DETAIL = "chat/{conversationId}"
    const val PROVIDER_DETAIL = "provider/{providerId}"

    fun chatDetail(id: String) = "chat/$id"
    fun providerDetail(id: String) = "provider/$id"
}

@Composable
fun MainScreen(container: AppContainer) {
    val navController = rememberNavController()
    val backStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = backStackEntry?.destination
    val scope = rememberCoroutineScope()

    val topLevelRoutes = setOf(Routes.CHATS, Routes.ASSISTANTS, Routes.PROVIDERS, Routes.USAGE)
    val showBottomBar = currentDestination?.route in topLevelRoutes

    val openNewChat: (PresetItem?) -> Unit = { preset ->
        scope.launch {
            val providers = container.chatRepository.getProviders()
            val ready = ChatRepository.readyTargets(providers)
            val defaultId = container.preferences.state.value.defaultTargetID
            val target = defaultId?.let { id -> ready.firstOrNull { it.id == id } } ?: ready.firstOrNull()
            val created = container.chatRepository.createConversation(preset = preset, primaryTarget = target)
            navController.navigate(Routes.chatDetail(created.id))
        }
    }

    val openNewArena: () -> Unit = {
        scope.launch {
            val providers = container.chatRepository.getProviders()
            val ready = ChatRepository.readyTargets(providers)
            val created = container.chatRepository.createConversation(
                isArenaMode = true,
                arenaTargets = ready.take(2)
            )
            navController.navigate(Routes.chatDetail(created.id))
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
                        icon = { Icon(Icons.Filled.AutoAwesome, contentDescription = null) },
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
                        icon = { Icon(Icons.Filled.Dns, contentDescription = null) },
                        label = { Text(stringResource(R.string.tab_providers)) }
                    )
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
                    onGoToProviders = {
                        navController.navigate(Routes.PROVIDERS) {
                            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    }
                )
            }
            composable(Routes.ASSISTANTS) {
                AssistantListScreen(
                    container = container,
                    onStartChatWithPreset = { preset -> openNewChat(preset) }
                )
            }
            composable(Routes.PROVIDERS) {
                ProviderListScreen(
                    container = container,
                    onOpenProvider = { id -> navController.navigate(Routes.providerDetail(id)) }
                )
            }
            composable(Routes.USAGE) {
                UsageScreen(container = container)
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
                    }
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
}
