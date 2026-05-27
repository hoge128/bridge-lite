import SwiftUI

struct OnboardingGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    @State private var enlargedImage: UIImage? = nil

    private var langCode: String {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        return lang.hasPrefix("ja") ? "ja" : "en"
    }

    private struct GuideStep {
        let title: LocalizedStringKey
        let desc: LocalizedStringKey
        let stepIndex: Int
        var descAlignment: TextAlignment = .center
    }

    private func loadImage(stepIndex: Int) -> UIImage? {
        guard let url = Bundle.main.url(
            forResource: "step\(stepIndex)",
            withExtension: "png",
            subdirectory: "exp-images/\(langCode)"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private var steps: [GuideStep] {
        [
            GuideStep(title: "guide.step0.title", desc: "guide.step0.desc", stepIndex: 0),
            GuideStep(title: "guide.step1.title", desc: "guide.step1.desc", stepIndex: 1),
            GuideStep(title: "guide.step2.title", desc: "guide.step2.desc", stepIndex: 2),
            GuideStep(title: "guide.step3.title", desc: "guide.step3.desc", stepIndex: 3, descAlignment: .leading),
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TabView(selection: $currentPage) {
                    ForEach(steps.indices, id: \.self) { i in
                        stepCard(steps[i], index: i)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 560)

                HStack(spacing: 9) {
                    ForEach(steps.indices, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut(duration: 0.15), value: currentPage)
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 16)
            .navigationTitle(Text("guide.title", tableName: nil))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .bold()
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { enlargedImage != nil },
                set: { if !$0 { enlargedImage = nil } }
            )) {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    if let img = enlargedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                    Button { enlargedImage = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                }
                .onTapGesture { enlargedImage = nil }
            }
        }
    }

    private func stepCard(_ step: GuideStep, index: Int) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Text("\(index + 1) / \(steps.count)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Text(step.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(step.desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(step.descAlignment)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: step.descAlignment == .leading ? .leading : .center)
            }
            .fixedSize(horizontal: false, vertical: true)

            Group {
                if let uiImage = loadImage(stepIndex: step.stepIndex) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                        .onTapGesture { enlargedImage = uiImage }
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.12))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
