{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE BangPatterns #-}
import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class
import Data.Int
import GHC.Stats
import Language.Javascript.JSaddle.Warp
import Reflex.Dom.Core
import System.Exit
import System.IO.Temp
import System.Mem
import System.Process

-- In initial testing, the minimum live bytes count was 233128 and maximum was
-- 363712.  Going over the maximum means the test has actually failed - we
-- probably have a memory leak; going under the minimum doesn't indicate a
-- memory leak, but may mean the test needs to be updated.
minBytesAllowed, resetThreshold, maxBytesAllowed :: Int64
(minBytesAllowed, resetThreshold, maxBytesAllowed) = (200000, 400000, 490000)

-- Some times the memory usage might flair up and then then return to normal
-- this probably indicates an issue, but if you are trying to fix a slow consistent
-- leak it can confuse the results by making the tests fail when the slow leak is
-- fixed.
-- Set this limit to say how many failures (currentBytesUsed > maxBytesAllowed)
-- want to ignore.  If the memory usage goes back under resetThreshold
-- the failure count is reset to 0.
failureLimit :: Int
failureLimit = 0

main :: IO ()
main = do
  mainThread <- myThreadId
  withSystemTempDirectory "reflex-dom-core_test_gc" $ \tmp -> do
    browserProcess <- spawnCommand $ "xvfb-run -a chromium --disable-gpu --user-data-dir=" ++ tmp ++ " http://localhost:3911"
    let finishTest result = mask_ $ do
          interruptProcessGroupOf browserProcess
          throwTo mainThread result
    forkIO $ watchProcess browserProcess (15 * 10^6) (Just "FAILED: browser process exited")
    run 3911 $ do
      -- enableLogging True
      liftIO $ putStrLn "Running..."
      mainWidget $ do
        let w = do
              rec let modifyAttrs = flip pushAlways (updated d) $ \_ -> sample $ current d
                  (e, _) <- element "button" (def & modifyAttributes .~ modifyAttrs) blank
                  d <- holdDyn mempty $ mempty <$ domEvent Click e
              return ()
        postBuild <- getPostBuild
        let f (!failures, !n) = liftIO $ if n < 3000
              then do performMajorGC
                      threadDelay 5000 -- Wait a bit to allow requestAnimationFrame to call its callback sometimes; this value was experimentally determined
                      gcStats <- getGCStats
                      print $ currentBytesUsed gcStats
                      when (currentBytesUsed gcStats < minBytesAllowed) $ do
                        putStrLn "FAILED: currentBytesUsed < minBytesAllowed"
                        finishTest $ ExitFailure 2
                      let overMax = currentBytesUsed gcStats > maxBytesAllowed
                          underReset = currentBytesUsed gcStats < resetThreshold
                      when (overMax && failures >= failureLimit) $ do
                        putStrLn "FAILED: currentBytesUsed > maxBytesAllowed"
                        finishTest $ ExitFailure 1
                      return $ Just (
                          if overMax
                              then succ failures
                              else (if underReset then 0 else failures), succ n)
              else do putStrLn "SUCCEEDED"
                      finishTest ExitSuccess
                      return Nothing
        rec redraw <- performEvent <=< delay 0 $ f <$> leftmost
              [ (0 :: Int, 0 :: Int) <$ postBuild
              , fmapMaybe id redraw
              ]
        _ <- widgetHold w $ w <$ redraw
        return ()
      liftIO $ forever $ threadDelay 1000000000

watchProcess :: ProcessHandle -> Int -> (ExitCode -> IO ()) -> Maybe String -> IO ()
watchProcess process interval onExit chatter = do
  status <- getProcessExitCode process
  case status of
    Nothing -> threadDelay interval >> watchProcess process interval onExit
    Just ec -> maybe (return ()) putStrnLn msg >> onExit ec
