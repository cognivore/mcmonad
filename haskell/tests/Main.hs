module Main where

import Test.QuickCheck hiding (allProperties)
import System.Exit
import Properties (allProperties)

main :: IO ()
main = do
    results <- mapM (\(name, prop) -> do
        putStr $ "  " ++ name ++ ": "
        r <- quickCheckResult (withMaxSuccess 500 prop)
        return (name, r)
        ) allProperties
    let failures = filter (\(_, r) -> not (isSuccess r)) results
    if null failures
        then putStrLn $ "\nAll " ++ show (length results) ++ " properties passed!"
        else do
            putStrLn $ "\n" ++ show (length failures) ++ " properties FAILED:"
            mapM_ (\(n, _) -> putStrLn $ "  FAIL: " ++ n) failures
            exitFailure
