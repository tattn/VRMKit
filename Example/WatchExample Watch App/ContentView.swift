//
//  ContentView.swift
//  WatchExample Watch App
//
//  Created by Naoto Komiya on 2023/09/08.
//  Copyright © 2023 tattn. All rights reserved.
//

import SwiftUI
import SceneKit

struct ContentView: View {
    @StateObject private var viewModel = ViewModel()

    var body: some View {
        SceneView(
            scene: viewModel.scene,
            delegate: viewModel.renderer
        )
        .ignoresSafeArea()
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
