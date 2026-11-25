import SwiftData
import SwiftUI

struct VoiceSettingsView: View {
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @State private var preferences = AppPreferences.shared

    private var openAIProviders: [ProviderConfig] {
        providers.filter {
            !$0.isDeleted && $0.isEnabled && ($0.protocolType == .openAICompatible || $0.protocolType == .openAIResponses) && $0.hasConfiguredChatAPI
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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("转写模型").font(.caption).foregroundStyle(.secondary)
                        TextField("默认：whisper-1", text: $preferences.audioTranscriptionModel)
                            .accessibilityLabel("转写模型")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.xs) {
                            ForEach(AudioTranscriptionService.presetModels, id: \.self) { model in
                                presetModelButton(model, selection: $preferences.audioTranscriptionModel)
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
                Text("录音与音频转文字")
            } footer: {
                Text("复用已配置服务商的 Base URL 与 Key；支持 OpenAI、Groq、硅基流动、OneAPI 及局域网 Whisper 服务。")
            }

            Section {
                Toggle("启用云端自然语音朗读", isOn: $preferences.useCloudTTS)

                if preferences.useCloudTTS && !openAIProviders.isEmpty {
                    Picker("朗读服务商", selection: $preferences.cloudTTSProviderID) {
                        Text("自动（首选兼容服务商）").tag(UUID?.none)
                        ForEach(openAIProviders) { provider in
                            Text(provider.name).tag(UUID?.some(provider.id))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("语音模型").font(.caption).foregroundStyle(.secondary)
                        TextField("默认：tts-1", text: $preferences.cloudTTSModel)
                            .accessibilityLabel("语音模型")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.xs) {
                            ForEach(CloudSpeechSynthesizer.presetModels, id: \.self) { model in
                                presetModelButton(model, selection: $preferences.cloudTTSModel)
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

            Section("高级功能") {
                DisclosureGroup("接口路径") {
                    LabeledContent("转写路径", value: "/audio/transcriptions")
                    LabeledContent("朗读路径", value: "/audio/speech")
                }
            }
        }
        .navigationTitle("语音转写与自然朗读")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func presetModelButton(_ model: String, selection: Binding<String>) -> some View {
        let selected = selection.wrappedValue == model
        return Button {
            selection.wrappedValue = model
            preferences.triggerSelectionHaptic()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: model)
                if selected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .font(.subheadline)
            .foregroundStyle(selected ? preferences.accentTheme.readableText : .primary)
            .padding(.horizontal, 12)
            .frame(minHeight: DS.TouchTarget.minimum + 2)
            .background(selected ? preferences.accentTheme.softFill : Color.secondary.opacity(0.10), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
