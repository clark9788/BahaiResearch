package com.bahairesearch.config;

/**
 * Immutable application configuration loaded from external properties.
 */
public record AppConfig(
    String geminiApiKey,
    String geminiModel,
    String noResultsText,
    boolean debugIntent,
    int maxQuotes,
    int requestTimeoutSeconds,
    String corpusBasePath,
    String corpusDatabaseFileName,
    String corpusSnapshotsDirName,
    String corpusIngestDirName,
    boolean corpusAutoInitialize,
    String corpusSourceBaseUrl,
    String corpusIngestSeedUrl,
    int corpusIngestMaxPages,
    int corpusIngestRequestDelayMillis,
    int corpusMinPassageLength,
    boolean corpusAutoIngestIfEmpty,
    boolean corpusForceReingest,
    boolean corpusCuratedIngestEnabled,
    String corpusCuratedBaseDir,
    String corpusCuratedManifestFileName
) {
}