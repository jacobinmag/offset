{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}

module Web.Offset.Feed where

import           Control.Monad.State
import           Data.Aeson          hiding (decode, encode, json, object)
import           Data.Aeson.Types    (parseMaybe)
import           Data.Maybe          (maybeToList, fromJust)
import           Data.Monoid
import qualified Data.Text           as T
import           Data.Time.Clock
import           Data.Time.Format    (formatTime, defaultTimeLocale)
import           Text.XML.Light
import           Web.Atom            hiding (Link)
import qualified Web.Atom            as A (Link (..))
import           Text.RSS            hiding (Link)
import qualified Text.RSS            as R (ItemElem (..))
import           Network.URI         (parseURI, URI)

import           Web.Offset.Date
import           Web.Offset.Link
import           Web.Offset.Splices
import           Web.Offset.Types
import           Web.Offset.Utils

data WPFeed =
  WPFeed { wpFeedURI     :: T.Text
         , wpFeedTitle   :: T.Text
         , wpFeedIcon    :: Maybe T.Text
         , wpFeedLogo    :: Maybe T.Text
         , wpBaseURI     :: T.Text
         , wpBuildLinks  :: Object -> [Link]
         , wpGetAuthors  :: WPAuthorStyle
         , wpRenderEntry :: Object -> IO (Maybe T.Text) }

data WPAuthorStyle = GuestAuthors | DefaultAuthor

generateRSSFeed :: IO String
generateRSSFeed = do
    currentTime <- getCurrentTime
    let formattedTime = formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S %z" currentTime

    -- Define the RSS channel
    -- let channel = RSSChannel
    --         { Title = "Example Channel"
    --         , Link = "https://www.example.com/"
    --         , Description = "This is an example of an RSS 2.0 feed."
    --         , Language = Just "en-us"
    --         , Copyright = Just "Copyright 2024 Example.com"
    --         , ManagingEditor = Just "editor@example.com"
    --         , WebMaster = Just "webmaster@example.com"
    --         , PubDate = Just formattedTime
    --         , LastBuildDate = Just formattedTime
    --         , Categories = []
    --         , Generator = Just "Haskell RSS Generator"
    --         , Docs = Just "https://www.rssboard.org/rss-specification"
    --         , Cloud = Nothing
    --         , TTL = Just 60
    --         , Image = Nothing
    --         , Rating = Nothing
    --         , TextInput = Nothing
    --         , SkipHours = []
    --         , SkipDays = []
    --         , Items = [item1, item2]
    --         }

    -- Define the RSS items
    let item1 = [
              Title "Example Item 1"
            , R.Link (fromJust (parseURI "https://www.example.com/example-item-1"))
            , Description "This is an example item description."
            , Author "author@email.com"
            , PubDate currentTime
            ]

    let item2 = [
              Title "Example Item 2"
            , R.Link (fromJust (parseURI "https://www.example.com/example-item-2"))
            , Description "This is another example item description."
            , Author "author@email.com"
            , PubDate currentTime
            ]


    -- Construct the RSS feed
    let rss = RSS  "Test Channel" (fromJust (parseURI "https://www.example.com/")) "This is an example of an RSS 2.0 feed."
                [ Language "en-us"
                , ManagingEditor "editor@example.com"
                , WebMaster "webmaster@example.com"
                , ChannelPubDate currentTime
                , LastBuildDate currentTime
                , TTL 60
                ]
                [item1, item2]

    -- Convert the RSS feed to XML
    return $ showXML $ rssToXML rss

toXMLFeed :: Wordpress b -> WPFeed -> IO T.Text
toXMLFeed wp wpFeed@(WPFeed uri title icon logo _ _ _ _) = do
  wpEntries <- getWPEntries wp
  let mostRecentUpdate = maximum (map wpEntryUpdated wpEntries)
  entries <- mapM (toEntry wp wpFeed) wpEntries
  let feed = (makeFeed (unsafeURI $ T.unpack uri) (TextPlain title) mostRecentUpdate)
             { feedIcon = unsafeURI <$> T.unpack <$> icon
             , feedLogo = unsafeURI <$> T.unpack <$> logo
             , feedEntries = entries }
  return $ T.pack $ ppTopElement $ fixNamespace $ feedXML xmlgen feed

fixNamespace :: Element -> Element
fixNamespace el@(Element _name attrs _content _line) =
  el { elAttribs = Attr (QName "xmlns" Nothing Nothing) "http://www.w3.org/2005/Atom" : attrs }

-- Copy-pasted from atom-basic docs
xmlgen :: XMLGen Element Text.XML.Light.Content QName Attr
xmlgen = XMLGen
    { xmlElem     = \n as ns    -> Element n as ns Nothing
    , xmlName     = \nsMay name -> QName (T.unpack name)
                                          (fmap T.unpack nsMay) Nothing
    , xmlAttr     = \k v        -> Attr k (T.unpack v)
    , xmlTextNode = \t          -> Text $ CData CDataText (T.unpack t) Nothing
    , xmlElemNode = Elem }

getWPEntries :: Wordpress b -> IO [WPEntry]
getWPEntries wp = do
  res <- liftIO $ cachingGetRetry wp (mkWPKey [] allPostsQuery)
  case res of
    Left statusCode -> error $ "Status code error: " ++ show statusCode
    Right resp ->
      case decodeWPResponseBody resp of
        Just posts -> return posts
        Nothing -> error $ "Couldn't decode: " <> show resp

allPostsQuery :: WPQuery
allPostsQuery =
  WPPostsQuery  { qlimit   = Just 20
                , qnum     = Just 20
                , qoffset  = Nothing
                , qpage    = Nothing
                , qorder   = Nothing
                , qorderby = Nothing
                , qsearch  = Nothing
                , qbefore  = Nothing
                , qafter   = Nothing
                , qstatus  = Nothing
                , qsticky  = Nothing
                , quser    = Nothing
                , qtaxes   = [] }

wpEntryContent :: (Object -> IO (Maybe T.Text))
               -> WPEntry
               -> IO (Maybe (Web.Atom.Content e))
wpEntryContent renderer wpentry =
  (fmap . fmap) InlineHTMLContent (renderer $ wpEntryJSON wpentry)

toEntry :: Wordpress b
        -> WPFeed
        -> WPEntry
        -> IO (Entry e)
toEntry wp wpFeed entry@WPEntry{..} = do
  content <- wpEntryContent (wpRenderEntry wpFeed) entry
  let guid = entryGuid (wpBaseURI wpFeed) wpEntryId wpEntryJSON
  let baseEntry = makeEntry guid (TextHTML wpEntryTitle) wpEntryUpdated
  authors <- case wpGetAuthors wpFeed of
               GuestAuthors -> getAuthorsInline wpEntryJSON
               DefaultAuthor -> getAuthorViaReq wp wpEntryJSON
  return $ baseEntry { entryPublished = Just wpEntryPublished
                     , entrySummary = Just (TextHTML wpEntrySummary)
                     , entryContent = content
                     , entryAuthors = map unWP authors
                     , entryLinks = map toAtomLink (wpBuildLinks wpFeed wpEntryJSON)}

toAtomLink :: Link -> A.Link
toAtomLink (Link href title) =
  A.Link { linkHref = unsafeURI $ T.unpack href
         , linkRel = Nothing
         , linkType = Nothing
         , linkHrefLang = Nothing
         , linkTitle = Just title
         , linkLength = Nothing }

data WPEntry =
  WPEntry { wpEntryId        :: Int
          , wpEntryTitle     :: T.Text
          , wpEntryUpdated   :: UTCTime
          , wpEntryPublished :: UTCTime
          , wpEntrySummary   :: T.Text
          , wpEntryJSON      :: Object } deriving (Eq, Show)

instance FromJSON WPEntry where
  parseJSON (Object v) =
    WPEntry <$> v .: "id" <*>
                (do t <- v .: "title"
                    t .: "rendered") <*>
                (jsonParseDate <$> (v .:"modified")) <*>
                (jsonParseDate <$> (v .: "date")) <*>
                (do e <- v .: "excerpt"
                    e .: "rendered") <*>
                return v
  parseJSON _ = error "bad post"

newtype WPPerson = WPPerson { unWP :: Person } deriving (Eq, Show)

instance FromJSON WPPerson where
  parseJSON (Object v) =
    WPPerson <$> (Person <$> v .: "name" <*> return Nothing <*> return Nothing)
  parseJSON _ = error "bad author"

getAuthorsInline :: Object -> IO [WPPerson]
getAuthorsInline v =
  do let authors = parseMaybe (\obj -> obj .: "authors") v
     case authors of
       Just list -> return list
       Nothing   -> return []

getAuthorViaReq :: Wordpress b -> Object -> IO [WPPerson]
getAuthorViaReq wp v =
  do let mAuthorId = parseMaybe (\obj -> obj .: "author") v :: Maybe Int
     case mAuthorId of
       Nothing -> return []
       Just authorId ->
         do eRespError <- cachingGetRetry wp (EndpointKey ("wp/v2/users/" <> tshow authorId) [])
            case eRespError of
              Left _ -> return []
              Right resp ->
                let mAuthorName = decodeWPResponseBody resp in
                  case mAuthorName of
                    Nothing -> return []
                    Just authorName ->return (maybeToList authorName)

entryGuid :: T.Text -> Int -> Object -> URI
entryGuid baseURI wpId wpJSON =
  unsafeURI $ T.unpack $
    case buildPermalink baseURI wpJSON of
      Just permalink -> Web.Offset.Link.linkHref permalink
      Nothing -> baseURI <> "/posts?id=" <> tshow wpId
