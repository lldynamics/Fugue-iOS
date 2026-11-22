import SwiftData
import SwiftUI

struct VoiceSettingsView: View {
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @State private var preferences = AppPreferences.shared

    private var openAIProviders: [ProviderConfig] {
        providers.filter {
            !$0.isDeleted && $0.isEnabled && $0.protocolType == .openAICompatible && $0.hasConfiguredChatAPI
        }
    }

    var body: some View {
        Form {
            Section {
                if openAIProviders.isEmpty {
                    Text("请先在「服务商与设置」中添加并启用至少一个 OpenAI 兼容服务商（如 OpenAI、Groq、硅基流动或本地 Whisper/Kokoro）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("转写服务商", selection: $preferences.audioTranscriptionProviderID) {
                        Text("自动（首选兼容服务商）").tag(UUID?.none)
                        ForEach(openAIProviders) { provider in
                            Text(provider.name).tag(UUID?.some(provider.id))
                        }
                    }

                    TextField("转写模型（默认 whisper-1）", text: $preferences.audioTranscriptionModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.xs) {
                            ForEach(AudioTranscriptionService.presetModels, id: \.self) { model in
                                Button(model) {
                                    preferences.audioTranscriptionModel = model
                                    preferences.triggerSelectionHaptic()
                                }
                                .buttonStyle(.bordered)
                                .tint(preferences.audioTranscriptionModel == model ? preferences.accentTheme.tintColor : .secondary)
                                .controlSize(.mini)
                            }
                        }
                    }

                    Picker("语言提示", selection: $preferences.audioTranscriptionLanguage) {
                        ForEach(AudioTranscriptionService.presetLanguages, id: \.code) { item in
                            Text(item.label).tag(item.code)
                        }
                    }
                }
            } header: {
                Text("录音与音频转文字 (/audio/transcriptions)")
            } footer: {
                Text("复用已配置服务商的 Base URL 与 Key；支持 OpenAI、Groq、硅基流动、OneAPI 及局域网 Whisper 服务。")
            }

            Section {
                Toggle("启用云端自然语音朗读 (/audio/speech)", isOn: $preferences.useCloudTTS)

                if preferences.useCloudTTS && !openAIProviders.isEmpty {
                    Picker("朗读服务商", selection: $preferences.cloudTTSProviderID) {
                        Text("自动（首选兼容服务商）").tag(UUID?.none)
                        ForEach(openAIProviders) { provider in
                            Text(provider.name).tag(UUID?.some(provider.id))
                        }
                    }

                    TextField("语音模型（默认 tts-1）", text: $preferences.cloudTTSModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.xs) {
                            ForEach(CloudSpeechSynthesizer.presetModels, id: \.self) { model in
                                Button(model) {
                                    preferences.cloudTTSModel = model
                                    preferences.triggerSelectionHaptic()
                                }
                                .buttonStyle(.bordered)
                                .tint(preferences.cloudTTSModel == model ? preferences.accentTheme.tintColor : .secondary)
                                .controlSize(.mini)
                            }
                        }
                    }

                    Picker("人声音色", selection: $preferences.cloudTTSVoice) {
                        ForEach(CloudSpeechSynthesizer.presetVoices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                }
            } header: {
                Text("语音朗读 (TTS)")
            } footer: {
                Text("开启后点击消息「朗读回复」会优先生成更自然的云端人声；如网络失败、未授权或无可用服务商，将自动静默回退到免费 iOS 系统语音。")
            }
        }
        .navigationTitle("语音转写与自然朗读")
        .navigationBarTitleDisplayMode(.inline)
    }
}
