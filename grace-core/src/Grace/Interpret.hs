{-# LANGUAGE BlockArguments     #-}
{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE QuasiQuotes        #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TypeApplications   #-}

-- | This module implements the main interpretation function
module Grace.Interpret
    ( -- * Interpret
      Input(..)
    , interpret
    , interpretWith

      -- * Errors related to interpretation
    , InterpretError(..)
    ) where

import Control.Exception.Safe (Exception(..), Handler(..), SomeException)
import Control.Monad.Except (MonadError(..))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Generics.Product (the)
import Data.String.Interpolate (__i)
import Data.Text (Text)
import Grace.Import (Input(..))
import Grace.Location (Location(..))
import Grace.Syntax (Node(..), Syntax(..))
import Grace.Type (Type)
import Grace.Value (Value)

import qualified Control.Exception.Safe as Exception
import qualified Control.Lens           as Lens
import qualified Control.Monad.Except   as Except
import qualified Data.Text              as Text
import qualified Grace.Context          as Context
import qualified Grace.Import           as Import
import qualified Grace.Import.Resolver  as Resolver
import qualified Grace.Infer            as Infer
import qualified Grace.Normalize        as Normalize
import qualified Grace.Parser           as Parser
import qualified Grace.Syntax           as Syntax
import qualified Text.URI               as URI

{-| Interpret Grace source code, return the inferred type and the evaluated
    result

    This is the top-level function for the Grace interpreter
-}
interpret
    :: (MonadError InterpretError m, MonadIO m)
    => Input
    -> m (Type Location, Value)
interpret = interpretWith [] Nothing

-- | Like `interpret`, but accepts a custom list of bindings
interpretWith
    :: (MonadError InterpretError m, MonadIO m)
    => [(Text, Type Location, Value)]
    -- ^ @(name, type, value)@ for each custom binding
    -> Maybe (Type Location)
    -- ^ Optional expected type for the input
    -> Input
    -> m (Type Location, Value)
interpretWith bindings maybeAnnotation input = do
    eitherPartiallyResolved <- do
        liftIO
            (Exception.catches
                (fmap Right (Import.resolverToCallback Resolver.defaultResolver input))
                [ Handler (\e -> return (Left (ParseError e)))
                , Handler (\e -> return (Left (ImportError input (displayException (e :: SomeException)))))
                ]
            )

    partiallyResolved <- case eitherPartiallyResolved of
        Left  interpretError    -> throwError interpretError
        Right partiallyResolved -> return partiallyResolved

    let process (maybeAnnotation', child) = do
            interpretWith bindings maybeAnnotation' (input <> child)

    resolvedExpression <- traverse process (annotate partiallyResolved)

    let annotatedExpression =
            case maybeAnnotation of
                Nothing         -> resolvedExpression
                Just annotation ->
                    Syntax
                        { node = Annotation resolvedExpression annotation
                        , location = Syntax.location resolvedExpression
                        }

    let typeContext = do
            (variable, type_, _) <- bindings

            return (Context.Annotation variable type_)

    case Infer.typeWith typeContext annotatedExpression of
        Left message -> do
            Except.throwError (TypeInferenceError message)

        Right inferred -> do
            let evaluationContext = do
                    (variable, _, value) <- bindings

                    return (variable, value)

            return (inferred, Normalize.evaluate evaluationContext resolvedExpression)

{-| We use this utility so that when we resolve an import of the form:

    > ./someImport.ffg : SomeType

    … then the type-annotation is used when type-checking the import.  This
    allows the user to supply an expected type to fix imports that would
    otherwise not type-check in isolation.  You can think of this function as
    \"pushing\" the type annotation into the imported expression.

    This is particularly useful when importing JSON.  For example, suppose
    that we had the following JSON expression:

    > [ 1, true ]

    We can't interpret that directly because it is a type error, and we also
    can't import that without a type annotation for the same reason.  However,
    we can import the JSON like this:

    > ./example.json : List (exists (a : Type) . a)

    … and the expression will succeed since the type annotation is used when
    type-checking @./example.json@.  We wouldn't be able to add that same type
    annotation directly to @./example.json@ because then it would no longer be
    valid JSON.
-}
annotate :: Syntax s a -> Syntax s (Maybe (Type s), a)
annotate = Lens.transform transformSyntax . fmap ((,) Nothing)
  where
    transformSyntax = Lens.over (the @"node") transformNode

    transformNode (Annotation Syntax{ node = Embed (_, a) } annotation) =
        Embed (Just annotation, a)
    transformNode node =
        node

-- | Errors related to interpretation of an expression
data InterpretError
    = ImportError Input String
    | ParseError Parser.ParseError
    | TypeInferenceError Infer.TypeInferenceError
    deriving stock (Eq, Show)

instance Exception InterpretError where
    displayException (ImportError input e) =
        Text.unpack [__i|
        #{renderInput}
        #{e}
        |]
      where
        renderInput = case input of
            URI  uri  -> URI.render uri
            Path path -> Text.pack path
            Code _ _  -> "(input)"
    displayException (ParseError e) = displayException e
    displayException (TypeInferenceError e) = displayException e
