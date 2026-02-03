import SwiftUI
import SceneKit

struct ContentView: View {
    @StateObject private var viewModel = ViewModel()

    var body: some View {
        TabView {
            SceneView(
                scene: viewModel.scene,
                delegate: viewModel.renderer
            )
            .ignoresSafeArea()
            
            VStack {
                Text("Select Model")
                Picker("Model", selection: $viewModel.selectedModelName) {
                    ForEach(ViewModel.ModelName.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.wheel)
            }
        }
        .tabViewStyle(.page)
        .onAppear {
            viewModel.loadModelIfNeeded()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
