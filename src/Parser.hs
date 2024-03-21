module Parser (parse) where

import AbstractSyntaxTree
import Tokens

{- |
  'parse' - Initiates parsing of tokens into a syntax tree of statements.

  Input:
    - '[Token]' - List of tokens generated by the scanner.

  Output:
    - 'Ast - Parsed abstract syntax tree of statements.
-}
parse :: [Token] -> Ast
parse [] = error "Empty list of Tokens!"
parse tokens
  | not $ isEOF (last tokens) = error $ "Input Tokens does not end with EOF:\n" ++ show tokens ++ "."
  | length tokens == 1 = error "Only <EOF> token was input."
  | otherwise =
      let statements = parseHelper tokens []
          errors = getAllErrors statements
       in if null errors
            then statements
            else error $ "Encountered errors while parsing:\n" ++ unlines (map show errors)

{- |
  'parseHelper' - Helper function for 'parse' to recursively build the syntax tree.

  Input:
    - '[Token]' - Remaining tokens to be parsed.
    - '[Stmt]' - Accumulated list of parsed statements.

  Output:
    - 'Ast' - Final abstract syntax tree including all statements.
-}
parseHelper :: [Token] -> [Stmt] -> Ast
parseHelper [] statements = error $ "Parsing error! Ran out of tokens, but managed to parse:\n" ++ show statements
parseHelper tokens@(t : ts) statementsAcc
  | null ts && isEOF t = Ast $ reverse statementsAcc
  | otherwise =
      let (declStatement, rest) = declaration tokens
          newStatementsAcc = declStatement : statementsAcc
       in case declStatement of
            (ErrorStmt _) ->
              let newRest = synchronize rest
               in parseHelper newRest newStatementsAcc
            _ -> parseHelper rest newStatementsAcc

{- |
  'declaration' - Parses a single declaration statement from tokens.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed declaration and remaining tokens.
-}
declaration :: [Token] -> (Stmt, [Token])
declaration [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
declaration tokens@(t : _)
  | isVarOrConst t = varDeclaration tokens
  | otherwise = statement tokens

{- |
  'varDeclaration' - Parses a variable declaration statement.

  Input:
    - '[Token]' - Tokens to be parsed, including CONST or VAR token.

  Output:
    - '(Stmt, [Token])' - The parsed variable declaration and remaining tokens.
-}
varDeclaration :: [Token] -> (Stmt, [Token])
varDeclaration [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
varDeclaration ((TOKEN varOrConstT _ _ _) : idToken@(TOKEN IDENTIFIER _ _ _) : (TOKEN EQUAL _ _ _) : exprTokens) =
  let (expr, restAfterExppresion) = expression exprTokens
      result = consume restAfterExppresion SEMICOLON "Expect ';' after expression." -- TODO: fix bug here
   in case result of
        Right restAfterConsume -> (VarDeclStmt varOrConstT idToken expr, restAfterConsume)
        Left err -> (ErrorStmt $ ErrorExpr err, restAfterExppresion)
varDeclaration ((TOKEN varOrConstT _ _ _) : idToken@(TOKEN IDENTIFIER _ _ _) : (TOKEN SEMICOLON _ _ _) : rest) = (VarDeclStmt varOrConstT idToken EmptyExpr, rest)
varDeclaration tokens@(t : _) = (ErrorStmt $ ErrorExpr $ LoxParseError ("Expect '=' or ';' after identifier, got: " ++ show t) t, tokens)

{- |
  'statement' - Parses a single statement from tokens.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed statement and remaining tokens.
-}
statement :: [Token] -> (Stmt, [Token])
statement [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
statement tokens@((TOKEN tokenType _ _ _) : ts)
  | tokenType == PRINT = printStatement ts
  | tokenType == LEFT_BRACE = block ts
  | tokenType == IF = ifStatement ts
  | tokenType == FOR = forStatement ts
  | tokenType == WHILE = whileStatement ts
  | otherwise = expressionStatement tokens

{- |
  'ifStatement' - Parses an 'if' statement, including potential 'else' branches.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed 'if' statement and remaining tokens.
-}
ifStatement :: [Token] -> (Stmt, [Token])
ifStatement [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
ifStatement tokens =
  let resultAfterLeftParen = consume tokens LEFT_PAREN "Expect '(' after 'if'."
   in case resultAfterLeftParen of
        Left err -> (ErrorStmt $ ErrorExpr err, tokens)
        Right restAfterConsumeLeftParen ->
          let (condition, restAfterCondition) = expression restAfterConsumeLeftParen
              resultAfterRightParen = consume restAfterCondition RIGHT_PAREN ("Expect ')' after if condition: '" ++ show condition ++ "'")
           in case resultAfterRightParen of
                Left err -> (ErrorStmt $ ErrorExpr err, restAfterCondition)
                Right restAfterRightParen ->
                  let (ifStmt, restAfterIfStatement@(t : restAfterElse)) = statement restAfterRightParen
                      (maybeElseStmt, finalRest) = case t of
                        (TOKEN ELSE _ _ _) ->
                          let (elseStmt, restAfterElseStatement) = statement restAfterElse
                           in (Just elseStmt, restAfterElseStatement)
                        _ -> (Nothing, restAfterIfStatement)
                   in (IfStmt condition ifStmt maybeElseStmt, finalRest)

{- |
  'forStatement' - Parses a 'for' loop statement.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed 'for' loop and remaining tokens.
-}
forStatement :: [Token] -> (Stmt, [Token])
forStatement [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
forStatement tokens =
  case forLoop tokens of
    Left err ->
      let tokensAfterFailure = synchronize tokens
       in (ErrorStmt $ ErrorExpr err, tokensAfterFailure)
    Right (Nothing, condExpr, incrExpr, bodyStmt, tokensAfterFor) ->
      let whileStmt = WhileStmt condExpr (BlockStmt $ bodyStmt : appendIncrementExprIfAny incrExpr)
       in (whileStmt, tokensAfterFor)
    Right (Just initStmt, condExpr, incrExpr, bodyStmt, tokensAfterFor) ->
      let whileStmt = WhileStmt condExpr (BlockStmt $ bodyStmt : appendIncrementExprIfAny incrExpr)
          forStmt = BlockStmt [initStmt, whileStmt]
       in (forStmt, tokensAfterFor)
 where
  appendIncrementExprIfAny EmptyExpr = []
  appendIncrementExprIfAny expr = [ExprStmt expr]

{- |
  'forLoop' - Helper function for forStatement. Helps parse tokens of a for loop into its basic expressions and
              statements.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - 'Either LoxParseError (Maybe Stmt, Expr, Expr, Stmt, [Token])' - The parsed parts of the 'for' loop.
-}
forLoop :: [Token] -> Either LoxParseError (Maybe Stmt, Expr, Expr, Stmt, [Token])
forLoop tokensAfterFor = do
  tokensAfterLeftParen <- consume tokensAfterFor LEFT_PAREN "Expect '(' after 'for'."
  (initStmt, tokensAfterInit) <- forLoopParseInitalizer tokensAfterLeftParen
  tokensAtCondition <- case initStmt of
    Just _ -> Right tokensAfterInit
    Nothing -> consume tokensAfterLeftParen SEMICOLON "Expect ';' after 'for ( varStmt'"

  (condition, tokensAtIncrement) <- forLoopParseCondition tokensAtCondition
  (increment, tokensAtBody) <- forLoopParseIncrement tokensAtIncrement

  let (body, tokensAfterBody) = statement tokensAtBody
  return (initStmt, condition, increment, body, tokensAfterBody)

-- Helper function for forLoop. Helps parse the first initialiser Stmt.
forLoopParseInitalizer :: [Token] -> Either LoxParseError (Maybe Stmt, [Token])
forLoopParseInitalizer tokens@((TOKEN SEMICOLON _ _ _) : _) = Right (Nothing, tokens)
forLoopParseInitalizer tokens@(t : _)
  | isVarOrConst t =
      let (varStmt, restAfterVarStmt) = varDeclaration tokens
       in Right (Just varStmt, restAfterVarStmt)
  | otherwise =
      let (exprStmt, restAfterExprStmt) = expressionStatement tokens
       in Right (Just exprStmt, restAfterExprStmt)

-- Helper function for forLoop. Helps parse the condition Expr.
forLoopParseCondition :: [Token] -> Either LoxParseError (Expr, [Token])
forLoopParseCondition ((TOKEN SEMICOLON _ _ _) : rest) = Right (EmptyExpr, rest)
forLoopParseCondition tokens = do
  let (condExpr, rest) = expression tokens
  tokensAtIncr <- consume rest SEMICOLON "Expect ';' after 'for ( varStmt ; cond'."
  Right (condExpr, tokensAtIncr)

-- Helper function for forLoop. Helps parse the increment Expr.
forLoopParseIncrement :: [Token] -> Either LoxParseError (Expr, [Token])
forLoopParseIncrement ((TOKEN RIGHT_PAREN _ _ _) : rest) = Right (EmptyExpr, rest)
forLoopParseIncrement tokens = do
  let (incrExpr, rest) = expression tokens
  tokensAtIncr <- consume rest RIGHT_PAREN "Expect ')' after 'for ( varStmt ; cond ; incr'."
  Right (incrExpr, tokensAtIncr)

{- |
  'whileStatement' - Parses a 'while' loop statement.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed 'while' loop and remaining tokens.
-}
whileStatement :: [Token] -> (Stmt, [Token])
whileStatement [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
whileStatement tokens =
  let resultAfterLeftParen = consume tokens LEFT_PAREN "Expect '(' after 'while'."
   in case resultAfterLeftParen of
        Left err -> (ErrorStmt $ ErrorExpr err, tokens)
        Right restAfterConsumeLeftParen ->
          let (condition, restAfterCondition) = expression restAfterConsumeLeftParen
              resultAfterRightParen = consume restAfterCondition RIGHT_PAREN ("Expect ')' after while condition: '" ++ show condition ++ "'")
           in case resultAfterRightParen of
                Left err -> (ErrorStmt $ ErrorExpr err, restAfterCondition)
                Right restAfterRightParen ->
                  let (whileStatement, restAfterWhileStatement) = statement restAfterRightParen
                   in (WhileStmt condition whileStatement, restAfterWhileStatement)

{- |
  'block' - Parses a block of statements enclosed in braces.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed block and remaining tokens.
-}
block :: [Token] -> (Stmt, [Token])
block [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
block tokens = blockHelper tokens []
 where
  blockHelper [] _ = error "Internal parser error. Nothing to parse, but parser expects statement in block."
  blockHelper rest@(t@(TOKEN tokenType _ _ _) : ts) tokensAcc
    | tokenType == EOF = (ErrorStmt $ ErrorExpr $ LoxParseError "Expect '}' after block" t, rest)
    | tokenType == RIGHT_BRACE = (BlockStmt $ reverse tokensAcc, ts)
    | otherwise =
        let (newStatement, statementRest) = declaration rest
         in blockHelper statementRest (newStatement : tokensAcc)

{- |
  'printStatement' - Parses a 'print' statement.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed 'print' statement and remaining tokens.
-}
printStatement :: [Token] -> (Stmt, [Token])
printStatement [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
printStatement tokens =
  let (expr, rest) = expression tokens
      result = consume rest SEMICOLON "Expect ';' after value."
   in case result of
        Right restAfterConsume -> (PrintStmt expr, restAfterConsume)
        Left err -> (ErrorStmt $ ErrorExpr err, rest)

{- |
  'expressionStatement' - Parses an expression used as a statement.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Stmt, [Token])' - The parsed expression statement and remaining tokens.
-}
expressionStatement :: [Token] -> (Stmt, [Token])
expressionStatement [] = (ErrorStmt $ ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
expressionStatement tokens =
  let (expr, rest) = expression tokens
      result = consume rest SEMICOLON "Expect ';' after expression."
   in case result of
        Right restAfterConsume -> (ExprStmt expr, restAfterConsume)
        Left err -> (ErrorStmt $ ErrorExpr err, rest)

{- |
  'expression' - Parses an expression.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed expression and remaining tokens.
-}
expression :: [Token] -> (Expr, [Token])
expression [] = error "Empty list of Tokens!"
expression tokens = assignment tokens

{- |
  'assignment' - Parses an assignment expression.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed assignment and remaining tokens.
-}
assignment :: [Token] -> (Expr, [Token])
assignment [] = (ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
assignment tokens@(possibleIdentifierToken : _) =
  let (left, restFromLeft) = loxOr tokens
   in case restFromLeft of
        ((TOKEN EQUAL _ _ _) : rest) ->
          if isTokenLValue possibleIdentifierToken
            then
              let (right, restFromRight) = assignment rest
               in (AssignExpr possibleIdentifierToken right, restFromRight)
            else
              let err = ErrorExpr $ LoxParseError ("Invalid assignment to rvalue: '" ++ show possibleIdentifierToken ++ "'") possibleIdentifierToken
                  newRest = synchronize rest
               in (err, newRest)
        _ -> (left, restFromLeft)
 where
  isTokenLValue (TOKEN IDENTIFIER _ _ _) = True
  isTokenLValue _ = False

{- |
  'loxOr' - Parses logical OR expressions.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed OR expression and remaining tokens.
-}
loxOr :: [Token] -> (Expr, [Token])
loxOr [] = (ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
loxOr tokens =
  let (left, restFromLeft) = loxAnd tokens
   in case left of
        err@(ErrorExpr _) -> (err, restFromLeft)
        _ -> matchOr left restFromLeft
 where
  matchOr left rest@(orToken@(TOKEN tokenType _ _ _) : ts)
    | tokenType == OR =
        let (right, restFromRight) = loxAnd ts
         in case right of
              err@(ErrorExpr _) -> (err, restFromRight)
              _ -> matchOr (BinaryExpr left orToken right) restFromRight
    | otherwise = (left, rest)

{- |
  'loxAnd' - Parses logical AND expressions.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed AND expression and remaining tokens.
-}
loxAnd :: [Token] -> (Expr, [Token])
loxAnd [] = (ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
loxAnd tokens =
  let (left, restFromLeft) = equality tokens
   in case left of
        err@(ErrorExpr _) -> (err, restFromLeft)
        _ -> matchAnd left restFromLeft
 where
  matchAnd left rest@(andToken@(TOKEN tokenType _ _ _) : ts)
    | tokenType == AND =
        let (right, restFromRight) = equality ts
         in case right of
              err@(ErrorExpr _) -> (err, restFromRight)
              _ -> matchAnd (BinaryExpr left andToken right) restFromRight
    | otherwise = (left, rest)

{- |
  'equality' - Parses equality and inequality expressions.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed equality/inequality expression and remaining tokens.
-}
equality :: [Token] -> (Expr, [Token])
equality [] = (ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
equality tokens =
  let (left, restFromLeft) = comparison tokens
   in case left of
        err@(ErrorExpr _) -> (err, restFromLeft)
        _ -> matchEqualities left restFromLeft
 where
  matchEqualities left rest@(t : ts)
    | isEquality t =
        let (right, restFromRight) = comparison ts
         in case right of
              err@(ErrorExpr _) -> (err, restFromRight)
              _ -> matchEqualities (BinaryExpr left t right) restFromRight
    | otherwise = (left, rest)

{- |
  'comparison' - Parses comparison expressions.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed comparison expression and remaining tokens.
-}
comparison :: [Token] -> (Expr, [Token])
comparison [] = (ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
comparison tokens =
  let (left, restFromLeft) = term tokens
   in case left of
        err@(ErrorExpr _) -> (err, restFromLeft)
        _ -> matchComparisions left restFromLeft
 where
  matchComparisions left rest@(t : ts)
    | isComparision t =
        let (right, restFromRight) = term ts
         in case right of
              err@(ErrorExpr _) -> (err, restFromRight)
              _ -> matchComparisions (BinaryExpr left t right) restFromRight
    | otherwise = (left, rest)

{- |
  'term' - Parses terms in addition and subtraction expressions.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed term and remaining tokens.
-}
term :: [Token] -> (Expr, [Token])
term [] = (ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
term tokens =
  let (left, restFromLeft) = factor tokens
   in case left of
        err@(ErrorExpr _) -> (err, restFromLeft)
        _ -> matchTerms left restFromLeft
 where
  matchTerms left rest@(t : ts)
    | isBinaryAdditive t =
        let (right, restFromRight) = factor ts
         in case right of
              err@(ErrorExpr _) -> (err, restFromRight)
              _ -> matchTerms (BinaryExpr left t right) restFromRight
    | otherwise = (left, rest)

{- |
  'factor' - Parses factors in multiplication and division expressions.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed factor and remaining tokens.
-}
factor :: [Token] -> (Expr, [Token])
factor [] = (ErrorExpr $ LoxParseError "Empty list of Tokens!" (TOKEN EOF "" NONE 0), [])
factor tokens =
  let (left, restFromLeft) = unary tokens
   in case left of
        err@(ErrorExpr _) -> (err, restFromLeft)
        _ -> matchFactors left restFromLeft
 where
  matchFactors left rest@(t : ts)
    | isBinaryMultiplicative t =
        let (right, restFromRight) = unary ts
         in case right of
              err@(ErrorExpr _) -> (err, restFromRight)
              _ -> matchFactors (BinaryExpr left t right) restFromRight
    | otherwise = (left, rest)

{- |
  'unary' - Parses unary expressions, including negation and logical NOT.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed unary expression and remaining tokens.
-}
unary :: [Token] -> (Expr, [Token])
unary tokens@(t : ts) =
  if isUnary t
    then
      let (right, rest) = unary ts
       in case right of
            ErrorExpr _ -> (right, rest)
            _ -> (UnaryExpr t right, rest)
    else primary tokens

{- |
  'primary' - Parses primary expressions, including literals, variables, and parenthesized expressions.

  Input:
    - '[Token]' - Tokens to be parsed.

  Output:
    - '(Expr, [Token])' - The parsed primary expression and remaining tokens.
-}
primary :: [Token] -> (Expr, [Token])
primary [] = error "Empty list of Tokens!"
primary tokens@(t@(TOKEN tokenType _ _ _) : ts)
  | isLiteral t = (LiteralExpr t, ts)
  | tokenType == RETURN = (LiteralExpr t, ts)
  | tokenType == LEFT_PAREN =
      let (left, rest) = expression ts
          result = consume rest RIGHT_PAREN "Expect ')' after expression."
       in case result of
            Right restAfterConsume -> (GroupingExpr left, restAfterConsume)
            Left err -> (ErrorExpr err, rest)
  -- \| otherwise = (EmptyExpr, tokens)

  | otherwise = (ErrorExpr $ LoxParseError "Unexpected Character" t, ts)

{- |
  'consume' - Consumes the next token if it matches the expected type, otherwise returns an error.

  Input:
    - '[Token]' - The remaining tokens.
    - 'TokenType' - The expected token type to consume.
    - 'String' - Error message to use if the expected token is not next.

  Output:
    - 'Either LoxParseError [Token]'  - The remaining tokens if successful, or an error.
-}
consume :: [Token] -> TokenType -> String -> Either LoxParseError [Token]
consume [] _ errorMessage = Left $ LoxParseError errorMessage (TOKEN EOF "" NONE 0)
consume (actual@(TOKEN actualTokenType _ _ _) : ts) expectedTokenType errorMessage
  | actualTokenType == expectedTokenType = Right ts
  | otherwise = Left $ LoxParseError errorMessage actual

{- |
  'synchronize' - Discards tokens until it reaches a statement boundary, used for error recovery.

  Input:
    - '[Token]' - The remaining tokens to be synchronized.

  Output:
    - '[Token]' - The tokens after synchronization.
-}
synchronize :: [Token] -> [Token]
synchronize [] = []
synchronize tokens@((TOKEN tokenType _ _ _) : ts)
  | tokenType == SEMICOLON = ts
  | tokenType == EOF = tokens
  | otherwise = synchronize ts
