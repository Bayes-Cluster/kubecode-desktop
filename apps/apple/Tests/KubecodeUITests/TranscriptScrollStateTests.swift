import Testing
@testable import KubecodeUI

@Suite
struct TranscriptScrollStateTests {
    @Test func follows_streaming_output_until_the_user_scrolls_away() {
        var state = TranscriptScrollState()

        let followsInitialOutput = state.outputDidChange()
        #expect(followsInitialOutput)
        #expect(state.followsOutput)
        #expect(!state.hasUnseenOutput)

        state.viewportDidChange(isNearBottom: false)

        let followsOutputAfterScrollingAway = state.outputDidChange()
        #expect(!followsOutputAfterScrollingAway)
        #expect(!state.followsOutput)
        #expect(state.hasUnseenOutput)
    }

    @Test func returning_to_the_bottom_resumes_following_and_clears_unseen_output() {
        var state = TranscriptScrollState()
        state.viewportDidChange(isNearBottom: false)
        _ = state.outputDidChange()

        state.viewportDidChange(isNearBottom: true)

        #expect(state.followsOutput)
        #expect(!state.hasUnseenOutput)
        let followsOutputAfterReturning = state.outputDidChange()
        #expect(followsOutputAfterReturning)
    }

    @Test func explicit_resume_restores_following_for_a_new_session() {
        var state = TranscriptScrollState()
        state.viewportDidChange(isNearBottom: false)
        _ = state.outputDidChange()

        state.resumeFollowing()

        #expect(state.followsOutput)
        #expect(!state.hasUnseenOutput)
    }
}
