Duration clampGifFrameDuration(
  Duration frameDuration, {
  Duration minimumGifFrameDuration = const Duration(milliseconds: 100),
}) {
  if (frameDuration <= const Duration(milliseconds: 10)) {
    return minimumGifFrameDuration;
  }

  return frameDuration;
}
