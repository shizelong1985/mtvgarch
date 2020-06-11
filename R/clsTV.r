## Changes for Demo

## --- tv_class Structure --- ####

## --- When created:

# Slots (internal variables for use in methods - should only be set by pkg_code)

    # tv@st             -- numeric: smooth transition variable
    # tv@g              -- numeric: conditional variances
    # tv@delta0free     -- logical: True if delta0 is a free param. If this TV object is part of an MTVGARCH object, then delta0 is a constant.
    # tv@nr.pars        -- integer: Number of model parameters. Decreases by 1 when tv@delta0free is True. (The Garch Components 'omega' parameter tracks the level)
    # tv@nr.transitions -- integer: number of transitions
    # tv@Tobs           -- integer: number of sample observations
    # tv@taylor.order   -- integer: Default=0. Used in Model-Specification to help determine next-transition shape

# properties (external variables, visible to user)

    # tv$shape          -- numeric: length = nr.transitions.
    # tv$speedopt       -- numeric: single integer value, set using enum
    # tv$delta0         -- numeric: single value
    # tv$pars           -- matrix: 4 x nr.transitions. Includes NA's for locN.2 where none exist
    # tv$optimcontrol   -- list: wrapper for the 'control' parameter sent to optim()

## --- After estimation:

    # tv$Estimated$value        -- scalar: log-liklihood value
    # tv$Estimated$error        -- logical: T/F indication if an error occurred during estimation
    # tv$Estimated$delta0
    # tv$Estimated$pars
    # tv$Estimated$hessian
    # tv$Estimated$se
    # tv$Estimated$optimoutput  -- list: the full returned value from optim().  Only set if the verbose param = True


## --- TV_CLASS Definition --- ####

tvshape = list(delta0only=0,single=1,double=2,double1loc=3)
speedopt = list(none=0,gamma=1,gamma_std=2,eta=3,lamda2_inv=4)

tv <- setClass(Class = "tv_class",
               slots = c(st="numeric",g="numeric",delta0free="logical",nr.pars="integer", nr.transitions="integer",Tobs="integer",taylor.order="integer"),
               contains = c("namedList")
               )

setMethod("initialize","tv_class",
          function(.Object,...){
            .Object <- callNextMethod(.Object,...)
            # Slots
            .Object@st <- c(NaN)
            .Object@g <- c(NaN)
            .Object@delta0free <- TRUE
            .Object@nr.pars <- as.integer(1)
            .Object@nr.transitions <- as.integer(0)
            .Object@Tobs <- as.integer(0)
            .Object@taylor.order <- as.integer(0)

            # Properties
            .Object$shape <- tvshape$delta0only
            .Object$speedopt <- speedopt$none
            .Object$delta0 <- 1.0
            .Object$pars <- matrix(NA,4,1)
            .Object$optimcontrol <- list(fnscale = -1, maxit = 1500, reltol = 1e-7)

            # Return:
            .Object
          })

setGeneric(name="tv",
           valueClass = "tv_class",
           signature = c("st","shape"),
           def = function(st,shape){

             # Validate shape:
             if(length(shape) > 1){
               if(any(shape == tvshape$delta0only)) stop("Invalid shape: delta0only / 0 is not a valid transition shape")
             }

             this <- new("tv_class")
             this$shape <- shape
             this@st <- st
             this@Tobs <- length(st)
             this@g <- rep(this$delta0,this@Tobs)

             if(shape[1] == tvshape$delta0only){
               this@nr.transitions <- as.integer(0)
               this$optimcontrol$ndeps <- c(1e-5)
               this$optimcontrol$parscale <- c(1)
             }else {
               this$speedopt <- speedopt$eta
               this@nr.transitions <- length(shape)
               # Create the starting Pars matrix
               this  <- .setInitialPars(this)
               rownames(this$pars) <- c("deltaN","speedN","locN1","locN2")
               this@nr.pars <- as.integer(length(this$pars[!is.na(this$pars)]) + 1)  # +1 for delta0
               this$optimcontrol$ndeps <- rep(1e-5,this@nr.pars)
               #TODO: Improve the parScale to better manage different Speed Options
               parScale <- rep(c(3,3,1,1),this@nr.transitions)
               # Tricky bit of 'maths' below to produce NA's in the NA locations  :P
               parScale <- parScale + (as.vector(this$pars) - as.vector(this$pars))
               this$optimcontrol$parscale <- c(3,parScale[!is.na(parScale)])

             }
             return(this)
           }
)

## --- Public Methods --- ####

## -- estimateTV(e,tv,ctrl) ####

setGeneric(name="estimateTV",
          valueClass = "tv_class",
          signature = c("e","tvObj","estimationControl"),
          def=function(e,tvObj,estimationControl){
            this <- tvObj
            this$Estimated <- list()

            if(!is.null(estimationControl$calcSE)) calcSE <- estimationControl$calcSE else calcSE <- FALSE
            if(!is.null(estimationControl$verbose)) verbose <- estimationControl$verbose else verbose <- FALSE

            # Check for the simple case of just delta0 provided, no TV$pars
            if(this@nr.transitions == 0){
              if(this@delta0free){
                this$Estimated$delta0 <- var(e)
                this@nr.pars <- as.integer(1)
              } else {
                if(is.null(this$Estimated$delta0)) this$Estimated$delta0 <- this$delta0
                this@nr.pars <- as.integer(0)
              }
              this@g <- rep(this$Estimated$delta0,this@Tobs)
              if(calcSE) this$Estimated$delta0_se <- NaN
              this$Estimated$pars <- NULL
              this$Estimated$value <- sum(-0.5*log(2*pi) - 0.5*log(this@g) - (0.5*e^2)/this@g)
              this$Estimated$error <- FALSE
              return(this)
            }

            # Start the Estimation process:
            if (verbose) {
              this$optimcontrol$trace <- 10
              cat("\nEstimating TV object...\n")
            } else this$optimcontrol$trace <- 0

            parsVec <- as.vector(this$pars)
            parsVec <- parsVec[!is.na(parsVec)]
            optimpars <- NULL
            # Set the Optimpars
            if(this@delta0free){
              optimpars <- c(this$delta0, parsVec)
            }else{
              optimpars <- parsVec
            }

            # Now call optim:
            tmp <- NULL
            try(tmp <- optim(optimpars,loglik.tv.univar,gr=NULL,e,this,method="BFGS",control=this$optimcontrol,hessian=calcSE))

            ## --- Attach results of estimation to the object --- ##

            # An unhandled error could result in a NULL being returned by optim()
            if (is.null(tmp)) {
              this$Estimated$value <- -Inf
              this$Estimated$error <- TRUE
              warning("estimateTV() - optim failed and returned NULL. Check the optim controls & starting params")
              return(this)
            }
            if (tmp$convergence != 0) {
              this$Estimated$value <- -Inf
              this$Estimated$error <- TRUE
              this$Estimated$optimoutput <- tmp
              warning("estimateTV() - failed to converge. Check the optim controls & starting params")
              return(this)
            }

            this$Estimated$value <- tmp$value
            this$Estimated$error <- FALSE

            #Update the TV object parameters using optimised pars:
            if (this@delta0free){
              this$Estimated$delta0 <- as.numeric(tmp$par[1])
              this <- .estimatedParsToMatrix(this,tail(tmp$par,-1))
            } else{
              if (is.null(this$Estimated$delta0)) this$Estimated$delta0 <- this$delta0
              this <- .estimatedParsToMatrix(this,tmp$par)
            }
            colnames(this$Estimated$pars) <- paste("st" ,1:this@nr.transitions,sep = "")

            # Get the conditional variances
            this@g <- .calculate_g(this)

            # Calc the std errors
            this$Estimated$delta0_se <- NULL
            this$Estimated$se <- NULL

            if (calcSE) {
              this$Estimated$hessian <- round(tmp$hessian,5)
              stdErrors <- NULL
              try(stdErrors <- sqrt(-diag(qr.solve(tmp$hessian))))
              if(!is.null(stdErrors)){
                parsVec <-  as.vector(this$pars)

                if (this@delta0free){
                  this$Estimated$delta0_se <- stdErrors[1]
                  stdErrors <- tail(stdErrors,-1)
                }

                seIndex <- 1
                for(n in seq_along(parsVec)){
                  if(!is.na(parsVec[n])) {
                    this$Estimated$se[n] <- stdErrors[seIndex]
                    seIndex <- seIndex + 1
                  } else this$Estimated$se[n] <- NaN
                }
                this$Estimated$se <- matrix(this$Estimated$se,nrow = 4)
                colnames(this$Estimated$se) <- paste("se" ,1:this@nr.transitions,sep = "")
              }
            }
            if (verbose) this$Estimated$optimoutput <- tmp

            return(this)
          })

setMethod("estimateTV",signature = c("numeric","tv_class","missing"),
          function(e,tvObj){
            estimationControl <- list()
            estimationControl$calcSE <- FALSE
            estimationControl$verbose <- FALSE
            estimationControl$taylor.order <- as.integer(0)
            estimateTV(e,tvObj,estimationControl)
          })

## -- LM.TR2(e,tv) ####
setGeneric(name="LM.TR2",
           valueClass = "numeric",
           signature = c("e","tvObj"),
           def=function(e,tvObj){
             this <- tvObj

             if(this@taylor.order == 0){
               message("Cannot execute test with no alternate hypothesis. Please set a valid taylor.order")
               return(NaN)
             }

             # Test Method: Regress psi2_1 on 1/gt*(dgdt and dgdt2)
             # 1. Calc derivatives of params dgdt = Tx1 or Tx4 or Tx7 or...
             #    NCOL(dgdt) increases with the order of TV function.
             dgdt <- .dg_dt(this)

             # 2. Calc derivatives of taylor pars (linearised component) under the null
             dgdt2 <- .dg_dt2(this@st)
             dgdt2 <- dgdt2[,(1:this@taylor.order),drop=FALSE]

             g <- .calculate_g(this)
             X <- cbind(dgdt,dgdt2)/g

             # 3. Invert crossprod(X) to calculate SSR1
             Xinv <- NULL
             try(Xinv <- qr.solve(crossprod(X)))
             if (is.null(Xinv)){
               rm(g,dgdt,dgdt2)
               return(NaN)
             }

             # 4. Calculate psi2_1 to calculate SSR0
             psi2_1 <- matrix(data=(e^2/g-1),nrow = this@Tobs,ncol = 1)

             # 5. Calc the TestStat:
             SSR0 <- sum(psi2_1*psi2_1)    # Scalar
             SSR1 <- sum((psi2_1-X%*%Xinv%*%t(X)%*%psi2_1)^2)

             Result <- this@Tobs*(SSR0-SSR1)/SSR0

             # Tidy up & release memory before returning:
             rm(this,psi2_1,g,X,Xinv,dgdt,dgdt2)

             # Return:
             Result

           }
)

## -- LM.Robust(e,tv) ####
setGeneric(name="LM.Robust",
           valueClass = "numeric",
           signature = c("e","tvObj"),
           def = function(e,tvObj){
             this <- tvObj

             if(this@taylor.order == 0){
               message("Cannot execute test with no alternate hypothesis. Please set a valid taylor.order")
               return(NaN)
             }
             # 1. Calc derivatives of params dgdt = Tx1 or Tx4 or Tx7 or...
             #    NCOL(dgdt) increases with the order of TV function.
             dgdt <- .dg_dt(this)

             # 2. Calc derivatives of taylor pars (linearised component) under the null
             dgdt2 <- .dg_dt2(this@st)
             dgdt2 <- dgdt2[,(1:this@taylor.order),drop=FALSE]

             g <- .calculate_g(this)
             X <- dgdt/g

             # 3. Invert crossprod(X) to calculate SSR1
             Xinv <- NULL
             try(Xinv <- qr.solve(crossprod(X)))
             if (is.null(Xinv)){
               message("error")
               rm(g,X,dgdt,dgdt2)
               return(NaN)
             }

             XXXX <- X%*%Xinv%*%t(X)
             Y <- as.matrix(dgdt2/g)
             W <- as.matrix(Y-XXXX%*%Y)

             #4. Regress 1 on (psi2-1)*w, and compute SSR
             psi2_1 <- as.vector(e^2/g - 1)
             X <- psi2_1*W  #psi2_1 must be a vector for this!!

             #5. Compute test statistic:
             Xinv <- NULL
             try(Xinv <- qr.solve(crossprod(X)))
             if(is.null(Xinv)) {
               message("error")
               rm(psi2_1,g,W,Y,X,XXXXdgdt,dgdt2)
               return(NaN)
             }

             Result <- this@Tobs-sum(diag(this@Tobs)-(X%*%Xinv%*%t(X)))

             # Tidy up & release memory before returning:
             rm(this,psi2_1,g,W,Y,X,XXXX,Xinv,dgdt,dgdt2)

             # Return:
             Result

           }
)

## -- SetTaylorOrder(tv) ####
setGeneric(name="setTaylorOrder",
           valueClass = "tv_class",
           signature = c("taylor.order","tvObj"),
           def = function(taylor.order,tvObj){
             this <- tvObj

             if(taylor.order > 0 && taylor.order < 5){
               this@taylor.order <- as.integer(taylor.order)
             } else{
               message("Invalid Taylor Order: Values 1 to 4 are supported")
             }
             return(this)
           }
)


## --- PRIVATE METHODS --- ####

## -- .testStatDist ####
setGeneric(name=".testStatDist",
           valueClass = "list",
           signature = c("tvObj","refdata","reftests","simcontrol"),
           def = function(tvObj,refdata,reftests,simcontrol){
             this <- tvObj

             # 1. Setup the default params & timer
             if(!is.null(simcontrol$saveAs)) {
               saveAs <- simcontrol$saveAs
             } else {
               saveAs <- paste("SimDist-",strftime(Sys.time(),format="%Y%m%d-%H%M%S",usetz = FALSE),sep = "")
             }
             if(!is.null(simcontrol$numLoops)) numLoops <- simcontrol$numLoops else numLoops <- 1100

             if(!is.null(simcontrol$numCores)) numCores <- simcontrol$numCores else numCores <- detectCores() - 1
             # Setup the parallel backend environment #
             Sys.setenv("MC_CORES" = numCores)
             cl <- makeCluster(numCores)
             registerDoParallel(cl, cores = numCores)
             #
             tmr <- proc.time()
             timestamp(prefix = "Starting Simulation on ",suffix = "\nPlease be patient as this may take a while...\n")

             # 2. Create Sim_Dist folder (if not there) & set Save filename
             if (!dir.exists(file.path(getwd(),"Sim_Dist"))) dir.create(file.path(getwd(),"Sim_Dist"))
             saveAs <- paste0(file.path("Sim_Dist",saveAs),".RDS")

             # 3. Load the generated data with Garch and add the 'g' from our TV object
             RefData_WithGarch <- refdata[1:this@Tobs,1:numLoops]
             RefData_WithGarch <- RefData_WithGarch*sqrt(this@g)

             # 4. Setup the matrix to store the simulation results - depends on the Order of TV function
             testStats <- matrix(NA,nrow=numLoops,ncol=8)

             # 5. Perform the simulation - in parallel
             testStats <- foreach(b = 1:numLoops, .inorder=FALSE, .combine=rbind, .verbose = FALSE) %dopar% {
               source("clsTV.r",local = TRUE)

               sim_e <- as.vector(RefData_WithGarch[,b])

               TV <- estimateTV(sim_e,this)    # Note: The tv params don't change, only the sim_e changes
               if (!TV$Estimated$error) {
                 if(!is.nan(reftests$LMTR2)) simTEST1 <- LM.TR2(sim_e,TV) else simTEST1 <- NaN
                 if(!is.nan(reftests$LMRobust)) simTEST2 <- LM.Robust(sim_e,TV) else simTEST2 <- NaN
                 runSimrow <- c(b,simTEST1,as.integer(simTEST1 > reftests$LMTR2),reftests$LMTR2,simTEST2,as.integer(simTEST2 > reftests$LMRobust),reftests$LMRobust,TV$Estimated$value)
               }
               # Progress indicator:
               if(b/100==round(b/100)) cat(".")

               #Result:
               runSimrow

             } # End: foreach(b = 1:numloops,...

             # 6. Save the distribution
             try(saveRDS(testStats,saveAs))

             # 7. Extract Test P_Values from Results & express as %
             colnames(testStats) <- c("b","Stat_TR2","Pval_TR2","Ref$LMTR2","Stat_Robust","Pval_Robust","Ref$LMRobust","Estimated_LL")
             Test <- list()
             Test$p_TR2 <- 100*mean(testStats[,"Pval_TR2"],na.rm = TRUE)
             Test$p_ROB <- 100*mean(testStats[,"Pval_Robust"],na.rm = TRUE)
             Test$Ref_TR2 <- testStats[1,"Ref$LMTR2"]
             Test$Ref_Robust <- testStats[1,"Ref$LMRobust"]
             Test$Stat_TR2 <- testStats[,"Stat_TR2"]
             Test$Stat_Robust <- testStats[,"Stat_Robust"]
             Test$TR2_Dist_Obs <- length(na.omit(testStats[,"Stat_TR2"]))
             Test$ROB_Dist_Obs <- length(na.omit(testStats[,"Stat_Robust"]))

             # 8. Print the time taken to the console:
             cat("\nSimulation Completed \nRuntime:",(proc.time()-tmr)[3],"seconds\n")

             # 9. Attempt to release memory:
             stopCluster(cl)
             rm(RefData_WithGarch,testStats)

             # Return:
             Test

           }
)

setMethod(".testStatDist",signature = c("tv_class","matrix","list","missing"),
          function(tvObj,refdata,reftests){
            simcontrol <- list()
            simcontrol$saveAs <- paste("SimDist-",strftime(Sys.time(),format="%Y%m%d-%H%M%S",usetz = FALSE))
            simcontrol$numLoops <- 1100
            simcontrol$numCores <- parallel::detectCores() - 1
            .testStatDist(tvObj,refdata,reftests,simcontrol)
          })


## Set the initial parameters ####
setGeneric(name=".setInitialPars",
           valueClass = "tv_class",
           signature = c("tvObj"),
           def = function(tvObj){
             this <- tvObj

             nrLoc <- this@nr.transitions + length(this$shape[this$shape==tvshape$double])
             locNum <- 1
             locDen <- nrLoc + 1
             pars <- NULL
             parNames <- NULL
             for(n in 1:this@nr.transitions){
               loc1 <- round(locNum/locDen,4)
               if(this$shape[n] == tvshape$double) {
                 loc2 <- round((locNum+1)/locDen,4)
                 locNum <- locNum + 2
               } else {
                 loc2 <- NA
                 locNum <- locNum + 2
               }
               pars <- c(pars,1,3,loc1,loc2)
             }
             this$pars <- matrix(pars,nrow=4)
             return(this)
           }
)

## Estimated Pars to Matrix ####
setGeneric(name=".estimatedParsToMatrix",
           valueClass = "tv_class",
           signature = c("tvObj","optimpars"),
           def = function(tvObj,optimpars){
             this <- tvObj

             if(this@nr.transitions == 0) stop("There are no parameters on this tv object")

             # Add NA's for all missing locn.2 pars:
             naPars <- NULL
             for (i in seq_along(this$shape)) {
               if (this$shape[i] == tvshape$double) {
                 naPars <- c(naPars,optimpars[1:4])
                 optimpars <- optimpars[-(1:4)]
               } else {
                 naPars <- c(naPars,optimpars[1:3],NA)
                 optimpars <- optimpars[-(1:3)]
               }
             }
             this$Estimated$pars <- matrix(naPars,nrow=4,ncol=NROW(this$shape),dimnames=list(c("deltaN","speedN","locN1","locN2"),NULL))

             # Return
             this
           }
)

## -- .dg_dt(tv) ####
setGeneric(name=".dg_dt",
           valueClass = "matrix",
           signature = c("tvObj"),
           def =  function(tvObj){

             this <- tvObj

             rtn <- matrix(nrow=this@Tobs,ncol=this@nr.pars)
             col_idx <- 0

             if(this@delta0free){
               col_idx <- col_idx + 1
               rtn[,col_idx] <- 1  # derivative of delta0
             }

             if (this@nr.transitions > 0) {
               # initialise some variables
               stdev_st <- sd(this@st)
               st_c <- speed_transf <- Gi <- 0

               for (i in 1:this@nr.transitions) {

                 if(this$shape[i] == tvshape$single) st_c <- this@st - this$Estimated$pars["locN1",i]
                 if(this$shape[i] == tvshape$double) st_c <- (this@st - this$Estimated$pars["locN1",i]) * (this@st - this$Estimated$pars["locN2",i])
                 if(this$shape[i] == tvshape$double1loc) st_c <- (this@st - this$Estimated$pars["locN1",i])^2

                 if(this$speedopt == speedopt$gamma) {
                   speed_transf <- this$Estimated$pars["speedN",i]
                   Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c))
                 }
                 if(this$speedopt == speedopt$gamma_std) {
                   speed_transf <- this$Estimated$pars["speedN",i]/stdev_st
                   Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c/stdev_st))
                 }
                 if(this$speedopt == speedopt$eta) {
                   speed_transf <- exp(this$Estimated$pars["speedN",i])
                   Gi <- 1/(1+exp(-exp(this$Estimated$pars["speedN",i]) * st_c))
                 }

                 deriv_const <- this$Estimated$pars["deltaN",i]*speed_transf*Gi*(1-Gi)

                 col_idx <- col_idx + 1
                 rtn[,col_idx] <- Gi    # derivative of delta1..n
                 col_idx <- col_idx + 1
                 rtn[,col_idx] <- deriv_const*st_c    # derivative of speed1..n

                 if(this$shape[i] == tvshape$single){
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const    # derivative of loc1..n (shape=TVshape$single)
                 }
                 if(this$shape[i] == tvshape$double){
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const*(this@st-this$Estimated$pars["locN1",i])  # derivative of loc1..n (shape=TVshape$double)
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const*(this@st-this$Estimated$pars["locN2",i])  # derivative of loc2..n (shape=TVshape$double)
                 }
                 if(this$shape[i] == tvshape$double1loc){
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const*2*(this@st-this$Estimated$pars["locN1",i])    # derivative of loc1..n (shape=TVshape$double1loc)
                 }

               } # End: for loop

             } # End: if (this@nr.transitions > 0)

             return(rtn)

           }
)


## -- .dg_dt2(tv@st) ####
setGeneric(name=".dg_dt2",
           valueClass = "matrix",
           signature = c("st"),
           def =  function(st){

             rtn <- matrix(1,NROW(st),4)
             rtn[,1] <- st
             rtn[,2] <- st^2
             rtn[,3] <- st^3
             rtn[,4] <- st^4
             # Return:
             rtn

           }
)

## -- .calculate_g(tv) ####
setGeneric(name=".calculate_g",
           valueClass = "numeric",
           signature = c("tvObj"),
           def = function(tvObj){

             this <- tvObj
             # 1. Initialise g to a constant variance = delta0
             if(is.null(this$Estimated$delta0)){
               # Set defaults if the TV object has not been estimated yet
               g <- rep(this$delta0,this@Tobs)
               this$Estimated$pars <- this$pars
             }else {
               g <- rep(this$Estimated$delta0,this@Tobs)
             }

             # 2. Update based on any transition parameters in the model
             if (this@nr.transitions > 0){
               st_c <- 0
               Gi <- 0
               # calulate 'g'
               for (i in 1:this@nr.transitions) {
                 if(this$shape[i] == tvshape$single) st_c <- this@st - this$Estimated$pars["locN1",i]
                 if(this$shape[i] == tvshape$double) st_c <- (this@st - this$Estimated$pars["locN1",i]) * (this@st - this$Estimated$pars["locN2",i])
                 if(this$shape[i] == tvshape$double1loc) st_c <- (this@st - this$Estimated$pars["locN1",i])^2

                 if(this$speedopt == speedopt$gamma) Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c))
                 if(this$speedopt == speedopt$gamma_std) Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c/sd(this@st)))
                 if(this$speedopt == speedopt$eta) Gi <- 1/(1+exp(-exp(this$Estimated$pars["speedN",i]) * st_c))

                 g <- g + this$Estimated$pars["deltaN",i]*Gi
               }
             }

             #Return:
             g
           }
)

## -- loglik.tv.univar() ####
setGeneric(name="loglik.tv.univar",
           valueClass = "numeric",
           signature = c("optimpars","e","tvObj"),
           def = function(optimpars,e,tvObj){

             this <- tvObj
             error <- -1e10

             # Copy the optimpars into a local tv_object
             if (this@delta0free) {
               this$Estimated$delta0 <- optimpars[1]
               this <- .estimatedParsToMatrix(this,tail(optimpars,-1))
             } else{
               if(is.null(this$Estimated$delta0)) this$Estimated$delta0 <- this$delta0
               this <- .estimatedParsToMatrix(this,optimpars)
             }

             # Do paramater boundary checks:
             # Check 1: Check that delta0 is positive
             if (this$Estimated$delta0 < 0) return(error)

             if (this@nr.transitions > 0){
               # We have some Tv$pars
               vecSpeed <- this$Estimated$pars["speedN",(1:this@nr.transitions)]
               vecLoc1 <- this$Estimated$pars["locN1",(1:this@nr.transitions)]
               vecLoc2 <- this$Estimated$pars["locN2",(1:this@nr.transitions)]

               # Check 2: Check the boundary values for speed params:
               #speedoptions: 1=gamma, 2=gamma/std(st), 3=exp(eta), 4=1/lambda^2
               maxSpeed <- switch(this$speedopt,1000,(1000/sd(this@st)),7.0,0.30)
               if (max(vecSpeed) > maxSpeed) return(error)
               if (min(vecSpeed) < 0) return(error)

               # Check 3: Check the loc1 locations fall within min-max values of st
               # We must have at least 1 loc1 to be inside this shape..loop, so no need to check if loc1 contains a valid value:
               if (min(vecLoc1) < min(this@st)) return(error)
               if (max(vecLoc1) > max(this@st)) return(error)

               # Check 4: Check that loc1.1 < loc1.2 .. locN.1 < locN.2 for all G(i)
               # Method: Subtract loc1_pos vector from loc2_pos vector and ensure it is positive:
               tmp <- vecLoc2 - vecLoc1
               # Note: tmp will contain NA wherever a loc2 element was NA - we can strip these out:
               if (sum(tmp < 0,na.rm = TRUE) > 0) return(error)

               # Check 5: Check the loc2 locations fall within min-max values of st
               # Confirm we have at least one valid numeric loc 2, before checking min & max:
               if (any(!is.na(vecLoc2))) {
                 if (min(vecLoc2,na.rm = TRUE) < min(this@st)) return(error)
                 if (max(vecLoc2,na.rm = TRUE) > max(this@st)) return(error)
               }

               # Check 6: Check that loc1.1 < loc2.1 where 2 locations exist... for all G(i)
               # We do need to have at least 2 locations for this error check
               if (NROW(vecLoc1) > 1) {
                 v1 <- head(vecLoc1,-1)
                 v2 <- tail(vecLoc1,-1)
                 if (sum(v2-v1 < 0) > 0) return(error)
               }

             }# End: paramater boundary checks:

             g <- .calculate_g(this)
             if (min(g,na.rm = TRUE) < 0) return(error)

             #Return the LogLiklihood value:
             sum( -0.5*log(2*pi) - 0.5*log(g) - 0.5*(e^2)/g )

           }
)

## --- Override Methods --- ####

## -- plot() ####
setMethod("plot",signature = c(x="tv_class",y="missing"),
          function(x, y,...){
            this <- x
            plot.default(x=this@g, type='l', ylab = "Cond.Variance", ...)
          })


## -- summary() ####
setMethod("summary",signature="tv_class",
          function(object,...){
          this <- object
          results <- NULL

          if(is.null(this$Estimated)){
            #
          } else{

            parsVec <-  round(as.vector(this$Estimated$pars),6)
            if(!is.null(this$Estimated$se) ){
              seVec <- round(as.vector(this$Estimated$se),6)
              seVecSig <- vector("character", length(seVec))

              for(n in seq_along(parsVec)){
                if(is.nan(seVec[n])) {
                  seVecSig[n] <- "   "
                  } else {
                    # Calculate a significance indicator
                    if(seVec[n]*2 < abs((parsVec[n]/100)) ) { (seVecSig[n] <- "***") }
                    else if(seVec[n]*2 < abs((parsVec[n]/10)) ) { (seVecSig[n] <- "** ") }
                    else if(seVec[n]*2 < abs((parsVec[n])) ) { (seVecSig[n] <- "*  ") }
                    }
                }
              } else {
                seVec <- rep(NaN,length(this$pars))
                seVecSig <- rep("   ", length(seVec))
              }

              seMat <- matrix(seVec,nrow=4)
              colnames(seMat) <- paste("se" ,1:this@nr.transitions,sep = "")
              # Build Results table and insert the significance indicators
              results <- data.frame(NA,stringsAsFactors = FALSE)
              for (n in 1:NCOL(this$Estimated$pars)){
                sig <- matrix(seVecSig[1:4],nrow=4)
                results <- cbind(results,round(this$Estimated$pars[,n,drop=F],6),seMat[,n,drop=F],sig)
                seVecSig <- tail(seVecSig,-4)
              }
            }

          cat("\nTV OBJECT\n")
          cat("\nEstimation Results:\n")
          if(is.null(this$Estimated$delta0_se)) this$Estimated$delta0_se <- NaN
          cat("\nDelta0 =",round(this$Estimated$delta0,6),"se0 = ",round(this$Estimated$delta0_se,6),"\n\n")
          print(results[,-1])
          cat("\nLog-liklihood value: ",this$Estimated$value)

})

