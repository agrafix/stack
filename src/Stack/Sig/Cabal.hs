{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ViewPatterns #-}

{-|
Module      : Stack.Sig.Cabal
Description : Cabal Functions
Copyright   : (c) FPComplete.com, 2015
License     : BSD3
Maintainer  : Tim Dysinger <tim@fpcomplete.com>
Stability   : experimental
Portability : POSIX
-}

module Stack.Sig.Cabal where

import qualified Codec.Archive.Tar as Tar
import           Conduit ((=$), ($$), runResourceT, sourceFile, sinkList,
                          linesUnboundedC, decodeUtf8C, concatMapC)
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Trans.Control
import qualified Data.ByteString.Lazy as BL
import           Data.List (intercalate, stripPrefix, isSuffixOf)
import           Data.List.Split (splitOn)
import           Data.Maybe (catMaybes)
import           Data.Monoid ((<>))
import           Data.String (fromString)
import qualified Data.Text as T
import           Data.Version (Version(..))
import           Distribution.Package  (PackageName(..), PackageIdentifier(..),
                                        pkgName, pkgVersion)
import           Distribution.PackageDescription (PackageDescription(..),
                                                  GenericPackageDescription(..))
import           Distribution.PackageDescription.Parse (readPackageDescription)
import           Distribution.Text (Text(disp), simpleParse)
import           Distribution.Verbosity (silent)
import           Stack.Types.Sig
import           System.Directory (doesFileExist, getAppUserDataDirectory)
import           System.Exit (ExitCode(..))
import           System.FilePath ((</>))
import           System.Process (waitForProcess, spawnProcess,
                                 readProcessWithExitCode)

cabalInstallDryRun :: forall (m :: * -> *).
                      (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
                   => [String] -> String -> m [PackageIdentifier]
cabalInstallDryRun opts pkg = do
    (code,out,err) <-
        liftIO
            (readProcessWithExitCode
                 "cabal"
                 ([ "install"
                  , "--dry-run"
                  , "--package-db=clear"
                  , "--package-db=global"] ++
                  opts ++
                  [pkg])
                 [])
    if code /= ExitSuccess
        then throwM (CabalPackageListException err)
        else return
                 (if (last . lines $ out) ==
                     "Use --reinstall if you want to reinstall anyway."
                      then []
                      else stdoutToPackageIdentifiers out)
    where stdoutToPackageIdentifiers :: String -> [PackageIdentifier]
          stdoutToPackageIdentifiers = map
                  (((\(version:reverseName) ->
                          -- TODO use the PI parser
                          PackageIdentifier
                              (PackageName
                                   (intercalate
                                        "-"
                                        (reverse reverseName)))
                              Version
                              { versionBranch = map read (splitOn "." version)
                              , versionTags = []
                              }) . {- FIXME Deprecated: "See GHC ticket #2496" -}
                    reverse .
                    splitOn "-") .
                   head .
                   splitOn " ") .
              drop 2 .
              lines

cabalFetch :: forall (m :: * -> *).
              (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
           => [String] -> PackageIdentifier -> m ()
cabalFetch opts (PackageIdentifier (PackageName name) (Version branch _tags)) = do
    let pkg = name <> "==" <>
            intercalate
                "."
                (map show branch)
    (code,_out,err) <-
        liftIO
            (readProcessWithExitCode
                 "cabal"
                 (["fetch"] ++
                  opts ++
                  [pkg])
                 [])
    unless (code == ExitSuccess)
        (throwM (CabalFetchException err))

cabalInstall :: forall (m :: * -> *).
                (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
             => [String] -> String -> m ()
cabalInstall opts pkg = do
    code <-
        liftIO
            (waitForProcess =<<
             spawnProcess
                 "cabal"
                 (["install"] ++
                  opts ++
                  [pkg]))
    unless (code == ExitSuccess)
        (throwM (CabalInstallException "unable to cabal-install"))

cabalFilePackageId :: forall (m :: * -> *).
                      (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
                   => FilePath -> m PackageIdentifier
cabalFilePackageId fp = return . package . packageDescription =<<
    liftIO (readPackageDescription silent fp)

packagesFromIndex :: forall (m :: * -> *).
                     (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
                  => m [PackageIdentifier]
packagesFromIndex = do
    indexPath <- getPackageIndexPath
    indexExists <-
        liftIO (doesFileExist indexPath)
    unless
        indexExists
        (throwM
             (CabalIndexException
                  ("Cabal index \"" <> indexPath <>
                   "\" is missing. Please run `cabal update` first.")))
    filePathsFromTarball [] .
        Tar.read =<<
        liftIO . BL.readFile =<< getPackageIndexPath
  where
    filePathsFromTarball _ (Tar.Fail err) = throwM
            (CabalIndexException
                 ("Unable to read the Cabal package index: " <> show err))
    filePathsFromTarball pkgs Tar.Done = (return . catMaybes) pkgs
    filePathsFromTarball pkgs (Tar.Next entry es) = case Tar.entryContent entry of
            Tar.NormalFile _ _
                | ".cabal" `isSuffixOf` Tar.entryPath entry ->
                    case splitOn "/" (Tar.entryPath entry) of
                        [] -> filePathsFromTarball pkgs es
                        [_] -> filePathsFromTarball pkgs es
                        (k:v:_) -> filePathsFromTarball
                                (simpleParse
                                     (k <> "-" <> v) :
                                 pkgs)
                                es
            _ -> filePathsFromTarball pkgs es

getPackageIndexPath :: forall (m :: * -> *).
                       (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
                    => m FilePath
getPackageIndexPath = do
    cabalCacheDir <- getCabalCacheDir
    return (cabalCacheDir </> "hackage.haskell.org" </> "00-index.tar")

getPackageTarballPath :: forall (m :: * -> *).
                       (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
                      => PackageIdentifier -> m FilePath
getPackageTarballPath pkg = do
    let pName = (show . disp . pkgName) pkg
        pVersion = (show . disp . pkgVersion) pkg
    cabalCacheDir <- getCabalCacheDir
    return
        (cabalCacheDir </> "hackage.haskell.org" </> pName </> pVersion </>
         (pName <> "-" <> pVersion <> ".tar.gz"))

getCabalCacheDir :: forall (m :: * -> *).
                    (Applicative m, MonadCatch m, MonadBaseControl IO m, MonadIO m, MonadMask m, MonadLogger m, MonadThrow m)
                 => m FilePath
getCabalCacheDir = do
    c <- liftIO (getAppUserDataDirectory "cabal")
    configLines <-
        runResourceT $
        sourceFile
            (fromString
                 (c </> "config")) $$
        decodeUtf8C =$
        linesUnboundedC =$
        concatMapC
            (getRemoteCache . T.unpack) =$
        sinkList
    case configLines of
        [x] -> return x
        [] -> throwM
                (CabalIndexException
                     "No remote-repo-cache found in Cabal config file")
        _ -> throwM
                (CabalIndexException
                     "Multiple remote-repo-cache entries found in Cabal config file")
  where
    getRemoteCache s = do
        ("remote-repo-cache",stripPrefix ": " -> Just v) <-
            Just (break (== ':') s)
        Just v