/// Rough characters-per-token for English prose and paths.
///
/// Deliberately not a real tokenizer: every budget here is a ceiling, and a
/// conservative estimate that overshoots slightly costs a little context,
/// while an exact count costs a tokenizer round-trip per chunk on a phone.
const double kCharsPerToken = 3.5;

int estimateTokens(String text) => (text.length / kCharsPerToken).ceil();
