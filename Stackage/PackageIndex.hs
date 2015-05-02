{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE ViewPatterns       #-}
{-# LANGUAGE GADTs              #-}
-- | Dealing with the 00-index file and all its cabal files.
module Stackage.PackageIndex
    ( sourcePackageIndex
    , UnparsedCabalFile (..)
    , getLatestDescriptions
    ) where

import qualified Codec.Archive.Tar                     as Tar
import           Data.Conduit.Lazy                     (MonadActive,
                                                        lazyConsume)
import qualified Data.Text                             as T
import           Distribution.PackageDescription       (package,
                                                        packageDescription)
import           Distribution.PackageDescription.Parse (ParseResult (..),
                                                        parsePackageDescription)
import           Distribution.ParseUtils               (PError)
import           Stackage.Prelude
import           System.Directory                      (getAppUserDataDirectory)

-- | Name of the 00-index.tar downloaded from Hackage.
getPackageIndexPath :: MonadIO m => m FilePath
getPackageIndexPath = liftIO $ do
    c <- getCabalRoot
    configLines <- runResourceT $ sourceFile (c </> "config")
                               $$ decodeUtf8C
                               =$ linesUnboundedC
                               =$ concatMapC getRemoteCache
                               =$ sinkList
    case configLines of
        [x] -> return $ x </> "hackage.haskell.org" </> "00-index.tar"
        [] -> error $ "No remote-repo-cache found in Cabal config file"
        _ -> error $ "Multiple remote-repo-cache entries found in Cabal config file"
  where
    getCabalRoot :: IO FilePath
    getCabalRoot = fpFromString <$> getAppUserDataDirectory "cabal"

    getRemoteCache s = do
        ("remote-repo-cache", stripPrefix ":" -> Just v) <- Just $ break (== ':') s
        Just $ fpFromText $ T.strip v

-- | A cabal file with name and version parsed from the filepath, and the
-- package description itself ready to be parsed. It's left in unparsed form
-- for efficiency.
data UnparsedCabalFile = UnparsedCabalFile
    { ucfName    :: PackageName
    , ucfVersion :: Version
    , ucfParse   :: forall m. MonadThrow m => m GenericPackageDescription
    }

-- | Stream all of the cabal files from the 00-index tar file.
sourcePackageIndex :: (MonadThrow m, MonadResource m, MonadActive m, MonadBaseControl IO m)
                   => Producer m UnparsedCabalFile
sourcePackageIndex = do
    fp <- getPackageIndexPath
    -- yay for the tar package. Use lazyConsume instead of readFile to get some
    -- kind of resource protection
    lbs <- lift $ fromChunks <$> lazyConsume (sourceFile fp)
    loop (Tar.read lbs)
  where
    loop (Tar.Next e es) = goE e >> loop es
    loop Tar.Done = return ()
    loop (Tar.Fail e) = throwM e

    goE e
        | Just front <- stripSuffix ".cabal" $ pack $ Tar.entryPath e
        , Tar.NormalFile lbs _size <- Tar.entryContent e = do
            (name, version) <- parseNameVersion front
            yield UnparsedCabalFile
                { ucfName = name
                , ucfVersion = version
                , ucfParse = goContent (Tar.entryPath e) name version lbs
                }
        | otherwise = return ()

    goContent fp name version lbs =
        case parsePackageDescription $ unpack $ dropBOM $ decodeUtf8 lbs of
            ParseFailed e -> throwM $ CabalParseException (fpFromString fp) e
            ParseOk _warnings gpd -> do
                let pd = packageDescription gpd
                    PackageIdentifier name' version' = package pd
                when (name /= name' || version /= version') $
                    throwM $ MismatchedNameVersion (fpFromString fp)
                        name name' version version'
                return gpd

    -- https://github.com/haskell/hackage-server/issues/351
    dropBOM t = fromMaybe t $ stripPrefix "\xFEFF" t

    parseNameVersion t1 = do
        let (p', t2) = break (== '/') $ T.replace "\\" "/" t1
        p <- simpleParse p'
        t3 <- maybe (throwM $ InvalidCabalPath t1 "no slash") return
            $ stripPrefix "/" t2
        let (v', t4) = break (== '/') t3
        v <- simpleParse v'
        when (t4 /= cons '/' p') $ throwM $ InvalidCabalPath t1 $ "Expected at end: " ++ p'
        return (p, v)

data InvalidCabalPath = InvalidCabalPath Text Text
    deriving (Show, Typeable)
instance Exception InvalidCabalPath

data CabalParseException = CabalParseException FilePath PError
                         | MismatchedNameVersion FilePath PackageName PackageName Version Version
    deriving (Show, Typeable)
instance Exception CabalParseException

-- | Get all of the latest descriptions for name/version pairs matching the
-- given criterion.
getLatestDescriptions :: MonadIO m
                      => (PackageName -> Version -> Bool)
                      -> (GenericPackageDescription -> IO desc)
                      -> m (Map PackageName desc)
getLatestDescriptions f parseDesc = liftIO $ do
    m <- runResourceT $ sourcePackageIndex $$ filterC f' =$ foldlC add mempty
    forM m $ \ucf -> liftIO $ ucfParse ucf >>= parseDesc
  where
    f' ucf = f (ucfName ucf) (ucfVersion ucf)
    add m ucf =
        case lookup name m of
            Just ucf' | ucfVersion ucf < ucfVersion ucf' -> m
            _ -> insertMap name ucf m
      where
        name = ucfName ucf
