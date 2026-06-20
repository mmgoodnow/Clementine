# Clementine MVP Goal

Build a SwiftUI flashcard app for iOS 26 and macOS 26 that uses FSRS-style scheduling, iCloud-synced user progress, and an HSK2-style Mandarin seed deck.

## Product Contract

- The user opens Clementine when they have time.
- Clementine chooses the best next card and the right amount of work.
- The user should not need to pick a daily quota or manually manage deck workload.

## Study Experience

- Prioritize hanzi-first cards for catching up from pinyin-only Mandarin study.
- Store vocabulary as one note with hanzi, pinyin, English, and optional lesson metadata.
- Generate multiple cards from a note over time, with the MVP focused on hanzi-first recognition and recall.
- Use mostly multiple choice, with occasional recall checks to avoid overestimating recognition-only memory.
- Map review results into FSRS grades: wrong to Again, slow/uncertain to Hard, normal correct to Good, fast/confident to Easy.
- Include a Low/Balanced/High learning-pace slider for new-card introduction.
- Use system Mandarin speech synthesis for v1 audio.

## Data And Sync

- Use SwiftData with CloudKit/iCloud sync.
- Bundle stable seed data separately from user review state.
- Keep HelloChinese scraping out of v1; use HSK2-style seed data first.

## Verification Requirement

- Run normal compile and unit-test gates before each commit.
- Do agentic manual testing of the macOS app because it is the easiest surface to inspect and iterate in this environment.
- Do agentic manual testing of the iOS app in Simulator for the core study flow and layout.
- Prefer real app launches and screenshots for UI verification over XCTest UI tests when code signing or Gatekeeper blocks unsigned test runners.
