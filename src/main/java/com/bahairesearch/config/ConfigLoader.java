package com.bahairesearch.config;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/**
 * Loads runtime configuration from a properties file pointed to by KEY_PATH.
 */
public final class ConfigLoader {

    private static final String ENV_KEY_PATH = "KEY_PATH";
    private static final String KEY_GEMINI_API_KEY = "gemini.apiKey";
    private static final String KEY_GEMINI_MODEL = "gemini.model";
    private static final String KEY_REQUIRED_SITE = "research.requiredSite";
    private static final String KEY_LOCAL_ONLY_MODE = "research.localOnlyMode";
    private static final String KEY_NO_RESULTS_TEXT = "research.noResultsText";
    private static final String KEY_DEBUG_INTENT = "research.debugIntent";
    private static final String KEY_PROMPT_BOILERPLATE = "research.promptBoilerplate";
    private static final String KEY_MAX_QUOTES = "research.maxQuotes";
    private static final String KEY_TIMEOUT_SECONDS = "research.requestTimeoutSeconds";
    private static final String KEY_CORPUS_BASE_PATH = "corpus.basePath";
    private static final String KEY_CORPUS_DB_FILE = "corpus.databaseFileName";
    private static final String KEY_CORPUS_SNAPSHOTS_DIR = "corpus.snapshotsDirName";
    private static final String KEY_CORPUS_INGEST_DIR = "corpus.ingestDirName";
    private static final String KEY_CORPUS_AUTO_INIT = "corpus.autoInitialize";
    private static final String KEY_CORPUS_SOURCE_BASE_URL = "corpus.sourceBaseUrl";
    private static final String KEY_CORPUS_INGEST_SEED_URL = "corpus.ingestSeedUrl";
    private static final String KEY_CORPUS_INGEST_MAX_PAGES = "corpus.ingestMaxPages";
    private static final String KEY_CORPUS_INGEST_DELAY_MS = "corpus.ingestRequestDelayMillis";
    private static final String KEY_CORPUS_MIN_PASSAGE_LENGTH = "corpus.minPassageLength";
    private static final String KEY_CORPUS_AUTO_INGEST_IF_EMPTY = "corpus.autoIngestIfEmpty";
    private static final String KEY_CORPUS_FORCE_REINGEST = "corpus.forceReingest";
    private static final String KEY_CORPUS_CURATED_INGEST_ENABLED = "corpus.curatedIngestEnabled";
    private static final String KEY_CORPUS_CURATED_BASE_DIR = "corpus.curated.baseDir";
    private static final String KEY_CORPUS_CURATED_MANIFEST_FILE = "corpus.curated.manifestFileName";

    private static final String DEFAULT_MODEL = "gemini-flash-latest";
    private static final String DEFAULT_REQUIRED_SITE = "https://oceanlibrary.com/";
    private static final boolean DEFAULT_LOCAL_ONLY_MODE = true;
    private static final String DEFAULT_NO_RESULTS_TEXT = "No Results";
    private static final boolean DEFAULT_DEBUG_INTENT = false;
    private static final String DEFAULT_PROMPT_BOILERPLATE =
        "Return quotes from primary Bahá’í scripture only. "
            + "For each quote include author, book title, and paragraph or page number. "
            + "If paragraph/page is unavailable, set paragraphOrPage to 'Not specified'. "
            + "Return No Results only when no relevant quotes can be found.";
    private static final int DEFAULT_MAX_QUOTES = 8;
    private static final int DEFAULT_TIMEOUT_SECONDS = 90;
    private static final String DEFAULT_CORPUS_BASE_PATH = "data/corpus";
    private static final String DEFAULT_CORPUS_DB_FILE = "corpus.db";
    private static final String DEFAULT_CORPUS_SNAPSHOTS_DIR = "snapshots";
    private static final String DEFAULT_CORPUS_INGEST_DIR = "ingest";
    private static final boolean DEFAULT_CORPUS_AUTO_INIT = true;
    private static final String DEFAULT_CORPUS_SOURCE_BASE_URL = "https://www.bahai.org";
    private static final String DEFAULT_CORPUS_INGEST_SEED_URL = "https://www.bahai.org/library/";
    private static final int DEFAULT_CORPUS_INGEST_MAX_PAGES = 200;
    private static final int DEFAULT_CORPUS_INGEST_DELAY_MS = 150;
    private static final int DEFAULT_CORPUS_MIN_PASSAGE_LENGTH = 80;
    private static final boolean DEFAULT_CORPUS_AUTO_INGEST_IF_EMPTY = true;
    private static final boolean DEFAULT_CORPUS_FORCE_REINGEST = false;
    private static final boolean DEFAULT_CORPUS_CURATED_INGEST_ENABLED = true;
    private static final String DEFAULT_CORPUS_CURATED_BASE_DIR = "curated/en";
    private static final String DEFAULT_CORPUS_CURATED_MANIFEST_FILE = "manifest.csv";

    private ConfigLoader() {
    }

    /**
     * Load application configuration from the KEY_PATH properties file.
     */
    public static AppConfig load() {
        String keyPathValue = System.getenv(ENV_KEY_PATH);
        if (isBlank(keyPathValue)) {
            keyPathValue = System.getProperty("bahai.keyPath");
        }
        if (isBlank(keyPathValue)) {
            throw new IllegalStateException("Missing KEY_PATH environment variable (or bahai.keyPath system property).");
        }

        Path keyPath = Path.of(keyPathValue);
        if (!Files.exists(keyPath)) {
            throw new IllegalStateException("KEY_PATH file does not exist: " + keyPath);
        }

        Properties properties = new Properties();
        try (InputStream inputStream = Files.newInputStream(keyPath)) {
            properties.load(inputStream);
        } catch (IOException exception) {
            throw new IllegalStateException("Unable to read KEY_PATH file: " + keyPath, exception);
        }

        boolean localOnlyMode = parseBoolean(properties.getProperty(KEY_LOCAL_ONLY_MODE), DEFAULT_LOCAL_ONLY_MODE);
        String geminiApiKey = valueOrEmpty(properties.getProperty(KEY_GEMINI_API_KEY));
        if (geminiApiKey.isEmpty() && !localOnlyMode) {
            throw new IllegalStateException("Missing required property when research.localOnlyMode=false: gemini.apiKey");
        }

        String model = valueOrDefault(properties.getProperty(KEY_GEMINI_MODEL), DEFAULT_MODEL);
        String requiredSite = valueOrDefault(properties.getProperty(KEY_REQUIRED_SITE), DEFAULT_REQUIRED_SITE);
        String noResultsText = valueOrDefault(properties.getProperty(KEY_NO_RESULTS_TEXT), DEFAULT_NO_RESULTS_TEXT);
        boolean debugIntent = parseBoolean(properties.getProperty(KEY_DEBUG_INTENT), DEFAULT_DEBUG_INTENT);
        String promptBoilerplate = valueOrDefault(
            properties.getProperty(KEY_PROMPT_BOILERPLATE),
            DEFAULT_PROMPT_BOILERPLATE
        );
        int maxQuotes = parsePositiveInt(properties.getProperty(KEY_MAX_QUOTES), DEFAULT_MAX_QUOTES);
        int timeoutSeconds = parsePositiveInt(properties.getProperty(KEY_TIMEOUT_SECONDS), DEFAULT_TIMEOUT_SECONDS);
        // bahai.corpusPath system property allows jpackage to pass an absolute path via
        // --java-options "-Dbahai.corpusPath=$APPDIR\data\corpus" without affecting dev setup.
        String corpusBasePath = System.getProperty("bahai.corpusPath");
        if (isBlank(corpusBasePath)) {
            corpusBasePath = valueOrDefault(properties.getProperty(KEY_CORPUS_BASE_PATH), DEFAULT_CORPUS_BASE_PATH);
        }
        String corpusDatabaseFileName =
            valueOrDefault(properties.getProperty(KEY_CORPUS_DB_FILE), DEFAULT_CORPUS_DB_FILE);
        String corpusSnapshotsDirName =
            valueOrDefault(properties.getProperty(KEY_CORPUS_SNAPSHOTS_DIR), DEFAULT_CORPUS_SNAPSHOTS_DIR);
        String corpusIngestDirName =
            valueOrDefault(properties.getProperty(KEY_CORPUS_INGEST_DIR), DEFAULT_CORPUS_INGEST_DIR);
        boolean corpusAutoInitialize =
            parseBoolean(properties.getProperty(KEY_CORPUS_AUTO_INIT), DEFAULT_CORPUS_AUTO_INIT);
        String corpusSourceBaseUrl =
            valueOrDefault(properties.getProperty(KEY_CORPUS_SOURCE_BASE_URL), DEFAULT_CORPUS_SOURCE_BASE_URL);
        String corpusIngestSeedUrl =
            valueOrDefault(properties.getProperty(KEY_CORPUS_INGEST_SEED_URL), DEFAULT_CORPUS_INGEST_SEED_URL);
        int corpusIngestMaxPages =
            parsePositiveInt(properties.getProperty(KEY_CORPUS_INGEST_MAX_PAGES), DEFAULT_CORPUS_INGEST_MAX_PAGES);
        int corpusIngestRequestDelayMillis =
            parseNonNegativeInt(properties.getProperty(KEY_CORPUS_INGEST_DELAY_MS), DEFAULT_CORPUS_INGEST_DELAY_MS);
        int corpusMinPassageLength =
            parsePositiveInt(properties.getProperty(KEY_CORPUS_MIN_PASSAGE_LENGTH), DEFAULT_CORPUS_MIN_PASSAGE_LENGTH);
        boolean corpusAutoIngestIfEmpty =
            parseBoolean(properties.getProperty(KEY_CORPUS_AUTO_INGEST_IF_EMPTY), DEFAULT_CORPUS_AUTO_INGEST_IF_EMPTY);
        boolean corpusForceReingest =
            parseBoolean(properties.getProperty(KEY_CORPUS_FORCE_REINGEST), DEFAULT_CORPUS_FORCE_REINGEST);
        boolean corpusCuratedIngestEnabled = parseBoolean(
            properties.getProperty(KEY_CORPUS_CURATED_INGEST_ENABLED),
            DEFAULT_CORPUS_CURATED_INGEST_ENABLED
        );
        String corpusCuratedBaseDir = valueOrDefault(
            properties.getProperty(KEY_CORPUS_CURATED_BASE_DIR),
            DEFAULT_CORPUS_CURATED_BASE_DIR
        );
        String corpusCuratedManifestFileName = valueOrDefault(
            properties.getProperty(KEY_CORPUS_CURATED_MANIFEST_FILE),
            DEFAULT_CORPUS_CURATED_MANIFEST_FILE
        );

        return new AppConfig(
            geminiApiKey,
            model,
            requiredSite,
            localOnlyMode,
            noResultsText,
            debugIntent,
            promptBoilerplate,
            maxQuotes,
            timeoutSeconds,
            corpusBasePath,
            corpusDatabaseFileName,
            corpusSnapshotsDirName,
            corpusIngestDirName,
            corpusAutoInitialize,
            corpusSourceBaseUrl,
            corpusIngestSeedUrl,
            corpusIngestMaxPages,
            corpusIngestRequestDelayMillis,
            corpusMinPassageLength,
            corpusAutoIngestIfEmpty,
            corpusForceReingest,
            corpusCuratedIngestEnabled,
            corpusCuratedBaseDir,
            corpusCuratedManifestFileName
        );
    }

    private static boolean parseBoolean(String rawValue, boolean defaultValue) {
        if (isBlank(rawValue)) {
            return defaultValue;
        }
        return Boolean.parseBoolean(rawValue.trim());
    }

    private static int parsePositiveInt(String rawValue, int defaultValue) {
        if (isBlank(rawValue)) {
            return defaultValue;
        }

        try {
            int parsed = Integer.parseInt(rawValue.trim());
            return parsed > 0 ? parsed : defaultValue;
        } catch (NumberFormatException exception) {
            return defaultValue;
        }
    }

    private static int parseNonNegativeInt(String rawValue, int defaultValue) {
        if (isBlank(rawValue)) {
            return defaultValue;
        }

        try {
            int parsed = Integer.parseInt(rawValue.trim());
            return parsed >= 0 ? parsed : defaultValue;
        } catch (NumberFormatException exception) {
            return defaultValue;
        }
    }

    private static String valueOrDefault(String value, String defaultValue) {
        return isBlank(value) ? defaultValue : value.trim();
    }

    private static String valueOrEmpty(String value) {
        return value == null ? "" : value.trim();
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }
}