//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Testing

@testable import ContainerBuild

struct BuildPipelineCompletionTests {
    @Test
    func commandCompleteEndsTheBuildPipeline() {
        var completion = Com_Apple_Container_Build_V1_RunComplete()
        completion.id = "build-id"
        var packet = ServerStream()
        packet.buildID = "build-id"
        packet.commandComplete = completion

        #expect(throws: Builder.Error.self) {
            try BuildPipeline.throwIfBuildComplete(packet)
        }
    }

    @Test
    func nonCompletionPacketsContinueTheBuildPipeline() throws {
        try BuildPipeline.throwIfBuildComplete(ServerStream())
    }
}
