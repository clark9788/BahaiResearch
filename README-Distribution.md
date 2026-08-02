# BahaiResearch

Desktop research assistant for finding sourced Bahá’í quotes from a **local authenticated corpus** (with optional AI-assisted intent/reranking).

## What this project does
- Windows 11 project
- Uses a local SQLite corpus for quote retrieval. Source titles are from baha.org/library
- Supports curated source ingest (DOCX/HTML/PDF) from `data/corpus/curated/en`
- Source files are downloaded and used to bring up the original source from the "Source" url under each passage returned
- On first run database is created on first run of Begin Research
- Returns structured results (quote, author, book, locator/page, URL)
- Can run in local-only mode (no web lookup at query time)
- Orginally was set up to use Gemini AI and look for quotes on the web, but there were hallucinations
- AI now evaluates research input and ranks words for search. It also tries to guess a good source -- author, title
- AI also ranks the returned quotes in order of most relevant
- Future plans to research other AI api's to see if they perform better.
- Each result includes a clickable Source link that opens the browser at the exact paragraph. Locators are HTML anchor IDs embedded in the bahai.org xhtml source files. For the 4 non-xhtml files (docx/pdf), Source opens the file in the registered OS handler (Word, Edge, etc.), but goes to the beginning of file. Use Search for these
- Used chatgpt-5.3-codex for original design and coding. Used sonnet-4.6 for improvements to search algorithm and finish
---

## Search Overview
The search algorithm is the strength of this tool. A two word query will result in a NEAR match, meaning the two words must be within 15(setable) characters of each other. A 3 word AND query will specifically match quotes with all three words in them. If the user comes up with three specific words they will get a quote that exactly matches. More than 3 words will be added to the query as OR matches, meaning if any of the words are included there will be a match. If there are no matches then the logic goes on to a full OR query where all words are used to bring back quotes with any of the words included. If the user has AI setup, then AI will look at the words and try to interpret the meaning. This can be a paragraph that descibes what the user is trying to find and AI will return most important words for the database lookup to use. AI will also help to rank query results if more than the number of quotes to be returned (8 by default) are found. A detailed explanation of the search logic is in the included Search_flow.md.

## Tech stack

- Java 21
- JavaFX
- SQLite
- Maven
- Inno Setup
- Optional Gemini API integration for intent/reranking

## Runtime configuration (`KEY_PATH`)
The app uses a default bahai-research.properties in the project root.
To use AI, set up an API key and save the bahai-research.properties file to include gemini.apiKey=YOUR_API_KEY (first property in the file)--see warning in next paragraph. All other properties are setup default in app. To change any from default, change in the root properties file or in the new KEY_PATH file if it is being used. An example would be research.maxQuotes=8 to another number to return a different number of quotes.  

The app reads settings from a properties file pointed to by environment variable `KEY_PATH`. If KEY_PATH is not set, it reads from project root .properties file. It is recommended to save the .properties file to a directory outside the project directory if adding an API_KEY. The API_KEY is like a credit card and should not be copied to others. A good spot would be a .credentials directory in your \users\Your-Logon\ directory. Create the directory and copy the baha-research.properties file there with api_key added.
Windows Start cmd.exe to set up Account environment variable
setx KEY_PATH "C:\Users\Your-logon\.credentials\bahai-research.properties"

Create a local file like `bahai-research.properties in a directory outside the app directory` (do **not** commit real secrets to your local copy within the local directory. Use the method above to store the KEY_PATH outside of the app directory.):

```properties
gemini.apiKey=YOUR_API_KEY
gemini.model=gemini-2.5-flash

research.debugIntent=false                       ** discarded for production
research.noResultsText=No Results                ** text for No Results in output
research.maxQuotes=8                             ** Change the number of quotes returned
research.requestTimeoutSeconds=90

corpus.basePath=data/corpus
corpus.databaseFileName=corpus.db
corpus.snapshotsDirName=snapshots
corpus.ingestDirName=ingest
corpus.autoInitialize=true

corpus.sourceBaseUrl=https://www.bahai.org       
corpus.ingestSeedUrl=https://www.bahai.org/library/  ** There is code to auto pull from the library. However, it was pulling arabic, persion, and lots of duplicates
corpus.ingestMaxPages=5000
corpus.ingestRequestDelayMillis=150
corpus.minPassageLength=80

corpus.autoIngestIfEmpty=false
corpus.forceReingest=false                          ** Causes database to be rebuilt. Do not leave true

corpus.curatedIngestEnabled=true
corpus.curated.baseDir=curated/en
corpus.curated.manifestFileName=manifest.csv
```
## Google API Creation
Creating an API key for Gemini is a straightforward process handled through Google AI Studio. This is the primary developer platform for prototyping with Gemini models.Step-By-Step: Creating Your API Key
Visit Google AI Studio:Go to aistudio.google.com. 
You will need to sign in with your standard Google account (Gmail or Workspace).Accept Terms:If it's your first time, you’ll be prompted to accept the Terms of Service. Review them and click Continue.
Navigate to API Keys:On the left-hand sidebar, click the button labeled "Get API key".
Generate the Key:Click the "Create API key" button.You will be asked to choose a Google Cloud project. If you don't have one, select "Create API key in new project". This will automatically set up the necessary backend infrastructure for you.
Copy and Secure:Once the key is generated, a string of characters will appear. Copy it immediately.⚠️ 
Security Note: Treat this key like a password. Do not hard-code it directly into your application's source code or upload it to public repositories like GitHub. Use Environment Variables (e.g., .env files) to keep it safe.

## Warnings on Install and Firewall warning
This installer is safe, but it is not yet code‑signed.
Because of this, Windows SmartScreen may display a warning such as “Windows protected your PC” or “Unknown publisher.”
To install:

Click More info or Keep Anyway
Click Run anyway or Delete(DownArrow) -Keep Anyway

This happens because the installer is newly published and has not yet built up Windows reputation.
No system files are modified outside the = install directory.

On first use, Windows Firewall may ask for permission for the Java HTML server to run. This server provides access to the HTML source files #anchor numbers to open file to exact location of quote, but does not need access through the firewall, so deny the firewall rule setup.