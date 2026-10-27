/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * libSparse: coordinate conversion, multiplication and the iterative solvers (CG, GMRES
 * variants, LSMR, preconditioners, single-step iteration), run on Apple's Accelerate and
 * Finch's and compared (tools/host-tests.sh). Direct factorizations are checked by hand
 * against Apple through invariants (their subfactors depend on each library's ordering).
 */
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdio.h>
#pragma clang diagnostic ignored "-Wunused-parameter"
static void conv_show(const char *n, SparseMatrix_Double A){
  int nc=A.structure.columnCount, bs=A.structure.blockSize;
  printf("%s: %dx%d bs %d attrs t%d tri%d kind%d alloc%d\n  starts", n, A.structure.rowCount, nc, bs, A.structure.attributes.transpose, A.structure.attributes.triangle, A.structure.attributes.kind, A.structure.attributes._allocatedBySparse);
  for(int j=0;j<=nc;j++) printf(" %ld", A.structure.columnStarts[j]); printf("\n  rows");
  for(long k=0;k<A.structure.columnStarts[nc];k++) printf(" %d", A.structure.rowIndices[k]); printf("\n  data");
  for(long k=0;k<A.structure.columnStarts[nc]*bs*bs;k++) printf(" %g", A.data[k]); printf("\n");
}
static void conv_mv(const char *n, SparseMatrix_Double A, int m, int nn){
  printf("  %s dense:", n);
  for(int j=0;j<nn;j++){ double x[16]={0}, y[16]; x[j]=1; for(int i=0;i<m;i++) y[i]=-1; SparseMultiply(A,(DenseVector_Double){nn,x},(DenseVector_Double){m,y}); printf(" ["); for(int i=0;i<m;i++)printf("%g ",y[i]); printf("]"); }
  printf("\n");
}
static void conv_tests(void){
  int r[]={0,2,1,0,2,1,2}, c[]={0,0,1,0,2,2,1}; double v[]={1,2,3,10,5,6,7};
  SparseAttributes_t at={0}; 
  SparseMatrix_Double A=SparseConvertFromCoordinate(3,3,7,1,at,r,c,v); conv_show("ordinary dup",A); conv_mv("A",A,3,3);
  at.kind=SparseSymmetric; at.triangle=SparseLowerTriangle;
  SparseMatrix_Double S=SparseConvertFromCoordinate(3,3,7,1,at,r,c,v); conv_show("sym lower",S); conv_mv("S",S,3,3);
  at.triangle=SparseUpperTriangle; SparseMatrix_Double U=SparseConvertFromCoordinate(3,3,7,1,at,r,c,v); conv_show("sym upper",U); conv_mv("U",U,3,3);
  at.kind=SparseTriangular; at.triangle=SparseLowerTriangle; SparseMatrix_Double T=SparseConvertFromCoordinate(3,3,7,1,at,r,c,v); conv_show("tri lower",T); conv_mv("T",T,3,3);
  at.kind=SparseUnitTriangular; SparseMatrix_Double UT=SparseConvertFromCoordinate(3,3,7,1,at,r,c,v); conv_show("unit tri lower",UT); conv_mv("UT",UT,3,3);
  SparseMatrix_Double At=SparseGetTranspose(A); conv_mv("A^T",At,3,3);
  SparseMatrix_Double Tt=SparseGetTranspose(T); conv_mv("T^T",Tt,3,3);
  // rectangular, block
  int rb[]={0,1,1}, cb[]={0,0,2}; double vb[]={1,2,3,4, 5,6,7,8, 9,10,11,12}; SparseAttributes_t a0={0};
  SparseMatrix_Double B=SparseConvertFromCoordinate(2,3,3,2,a0,rb,cb,vb); conv_show("block",B); conv_mv("B",B,4,6);
  // multiply-add with alpha, matrix
  double X[6]={1,2,3,4,5,6}, Y[6]={1,1,1,1,1,1};
  SparseMultiplyAdd(2.0,A,(DenseMatrix_Double){3,2,3,{0},X},(DenseMatrix_Double){3,2,3,{0},Y}); printf("  madd: %g %g %g %g %g %g\n",Y[0],Y[1],Y[2],Y[3],Y[4],Y[5]);
  SparseAttributes_t tr={0}; tr.transpose=1; double Y2[6]={0};
  SparseMultiply(A,(DenseMatrix_Double){2,3,2,tr,X},(DenseMatrix_Double){2,3,2,tr,Y2}); printf("  transposed dense: %g %g %g %g %g %g\n",Y2[0],Y2[1],Y2[2],Y2[3],Y2[4],Y2[5]);
}
static SparseMatrix_Double iter_mk(int m,int n,const double *d,int kind){ int r[256],c[256]; double v[256]; long k=0; SparseAttributes_t a={0}; a.kind=kind; a.triangle=SparseLowerTriangle;
  for(int j=0;j<n;j++)for(int i=0;i<m;i++) if(d[i*n+j]!=0 && (kind!=SparseSymmetric || i>=j)){r[k]=i;c[k]=j;v[k]=d[i*n+j];k++;}
  return SparseConvertFromCoordinate(m,n,k,1,a,r,c,v);}
static void iter_pv(const char *l, int st, const double *x, int n){ printf("  %s: status %d:",l,st); for(int i=0;i<n;i++) printf(" %.6g",fabs(x[i])<1e-9?0:x[i]); printf("\n"); }
static void iter_perr(const char *m){ printf("  [error %s]\n", m); }
static int iter_lines; static void iter_status(const char *m){ (void)m; iter_lines++; }
static void iter_tests(void){
  enum{N=8}; double A[N*N]={0}, U[N*N]={0};
  for(int i=0;i<N;i++){ A[i*N+i]=4; if(i>0){A[i*N+i-1]=-1;A[(i-1)*N+i]=-1;} U[i*N+i]=3+i; if(i+1<N) U[i*N+i+1]=1; if(i>1) U[i*N+i-2]=-1; }
  SparseMatrix_Double S=iter_mk(N,N,A,SparseSymmetric), G=iter_mk(N,N,U,0);
  double b[N]; for(int i=0;i<N;i++) b[i]=i+1;
  double x[N];
  #define RUN(label, call) do{ for(int i=0;i<N;i++) x[i]=0; int st=call; iter_pv(label,st,x,N);}while(0)
  RUN("cg", SparseSolve(SparseConjugateGradient((SparseCGOptions){.reportError=iter_perr}), S, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  RUN("cg diag", SparseSolve(SparseConjugateGradient((SparseCGOptions){.reportError=iter_perr}), S, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}, SparsePreconditionerDiagonal));
  RUN("cg 3 its", SparseSolve(SparseConjugateGradient((SparseCGOptions){.maxIterations=3,.reportError=iter_perr}), S, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  RUN("gmres", SparseSolve(SparseGMRES((SparseGMRESOptions){.reportError=iter_perr}), G, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  RUN("gmres std nvec3", SparseSolve(SparseGMRES((SparseGMRESOptions){.reportError=iter_perr,.variant=SparseVariantGMRES,.nvec=3}), G, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  RUN("fgmres diag", SparseSolve(SparseGMRES((SparseGMRESOptions){.reportError=iter_perr,.variant=SparseVariantFGMRES}), G, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}, SparsePreconditionerDiagonal));
  RUN("gmres 2 its", SparseSolve(SparseGMRES((SparseGMRESOptions){.reportError=iter_perr,.maxIterations=2}), G, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  RUN("lsmr square", SparseSolve(SparseLSMR((SparseLSMROptions){.reportError=iter_perr}), G, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  double R[12*N]={0}; for(int i=0;i<12;i++) for(int j=0;j<N;j++) if((i+j)%3==0 || i==j) R[i*N+j]=1+((i*7+j)%5);
  SparseMatrix_Double Rm=iter_mk(12,N,R,0); double br[12]; for(int i=0;i<12;i++) br[i]=1+i%4;
  RUN("lsmr rect", SparseSolve(SparseLSMR((SparseLSMROptions){.reportError=iter_perr}), Rm, (DenseVector_Double){12,br}, (DenseVector_Double){N,x}));
  RUN("lsmr rect diagscaling", SparseSolve(SparseLSMR((SparseLSMROptions){.reportError=iter_perr}), Rm, (DenseVector_Double){12,br}, (DenseVector_Double){N,x}, SparsePreconditionerDiagScaling));
  RUN("lsmr fong", SparseSolve(SparseLSMR((SparseLSMROptions){.reportError=iter_perr,.convergenceTest=SparseLSMRCTFongSaunders}), Rm, (DenseVector_Double){12,br}, (DenseVector_Double){N,x}));
  RUN("lsmr damped", SparseSolve(SparseLSMR((SparseLSMROptions){.reportError=iter_perr,.lambda=0.5}), Rm, (DenseVector_Double){12,br}, (DenseVector_Double){N,x}));
  double ind[N*N]={0}; for(int i=0;i<N;i++){ ind[i*N+i]= i%2? -2:2; if(i>0){ind[i*N+i-1]=1;ind[(i-1)*N+i]=1;} }
  RUN("cg indefinite", SparseSolve(SparseConjugateGradient((SparseCGOptions){.reportError=iter_perr}), iter_mk(N,N,ind,SparseSymmetric), (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  iter_lines=0; RUN("cg status", SparseSolve(SparseConjugateGradient((SparseCGOptions){.reportError=iter_perr,.reportStatus=iter_status}), S, (DenseVector_Double){N,b}, (DenseVector_Double){N,x})); printf("  status lines %d\n", iter_lines>0);
  // block operator form
  RUN("cg block", SparseSolve(SparseConjugateGradient((SparseCGOptions){.reportError=iter_perr}), ^(bool acc, enum CBLAS_TRANSPOSE t, DenseVector_Double X, DenseVector_Double Y){ (void)t; for(int i=0;i<N;i++){ double s=4*X.data[i]-(i?X.data[i-1]:0)-(i<N-1?X.data[i+1]:0); Y.data[i]= acc? Y.data[i]+s : s; } }, (DenseVector_Double){N,b}, (DenseVector_Double){N,x}));
  // multiple rhs
  double B2[2*N], X2[2*N]={0}; for(int i=0;i<N;i++){B2[i]=1;B2[N+i]=i;}
  int st=SparseSolve(SparseConjugateGradient((SparseCGOptions){.reportError=iter_perr}), S, (DenseMatrix_Double){N,2,N,{0},B2}, (DenseMatrix_Double){N,2,N,{0},X2}); iter_pv("cg 2 rhs",st,X2,2*N);
  // iterate API
  { SparseIterativeMethod m=SparseConjugateGradient((SparseCGOptions){.reportError=iter_perr}); size_t sz=SparseGetStateSize_Double(m,false,N,N,1); char *state=malloc(sz); double xx[N]={0}, rr[N]; for(int i=0;i<N;i++) rr[i]=b[i]; bool conv=false;
    int it; for(it=0; it<50; it++){ SparseIterate(m,it,&conv,state,^(bool acc, enum CBLAS_TRANSPOSE t, DenseMatrix_Double X, DenseMatrix_Double Y){ if(acc) SparseMultiplyAdd(S,X,Y); else SparseMultiply(S,X,Y); (void)t;}, (DenseMatrix_Double){N,1,N,{0},b},(DenseMatrix_Double){N,1,N,{0},rr},(DenseMatrix_Double){N,1,N,{0},xx}); if(rr[0]<1e-10) break; }
    SparseIterate(m,-1,&conv,state,^(bool acc, enum CBLAS_TRANSPOSE t, DenseMatrix_Double X, DenseMatrix_Double Y){ if(acc) SparseMultiplyAdd(S,X,Y); else SparseMultiply(S,X,Y); (void)t;}, (DenseMatrix_Double){N,1,N,{0},b},(DenseMatrix_Double){N,1,N,{0},rr},(DenseMatrix_Double){N,1,N,{0},xx});
    iter_pv("cg iterate",it,xx,N); iter_pv("final residual",0,rr,N); free(state); }
  { SparseIterativeMethod m=SparseGMRES((SparseGMRESOptions){.reportError=iter_perr}); size_t sz=SparseGetStateSize_Double(m,false,N,N,1); char *state=malloc(sz); double xx[N]={0}, rr[N]; for(int i=0;i<N;i++) rr[i]=b[i]; bool conv=false;
    int it; for(it=0; it<50; it++){ SparseIterate(m,it,&conv,state,^(bool acc, enum CBLAS_TRANSPOSE t, DenseMatrix_Double X, DenseMatrix_Double Y){ if(acc) SparseMultiplyAdd(G,X,Y); else SparseMultiply(G,X,Y); (void)t;}, (DenseMatrix_Double){N,1,N,{0},b},(DenseMatrix_Double){N,1,N,{0},rr},(DenseMatrix_Double){N,1,N,{0},xx}); if(rr[0]<1e-10) break; }
    SparseIterate(m,-1,&conv,state,^(bool acc, enum CBLAS_TRANSPOSE t, DenseMatrix_Double X, DenseMatrix_Double Y){ if(acc) SparseMultiplyAdd(G,X,Y); else SparseMultiply(G,X,Y); (void)t;}, (DenseMatrix_Double){N,1,N,{0},b},(DenseMatrix_Double){N,1,N,{0},rr},(DenseMatrix_Double){N,1,N,{0},xx});
    iter_pv("gmres iterate",it,xx,N); iter_pv("final residual",0,rr,N); free(state); }
}

int main(void)
{
	setvbuf(stdout, 0, _IONBF, 0);
	conv_tests();
	iter_tests();
	return 0;
}
